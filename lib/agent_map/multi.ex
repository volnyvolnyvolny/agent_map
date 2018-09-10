defmodule AgentMap.Multi do
  alias AgentMap.Multi.Req

  import AgentMap, only: [pid: 1, _call: 3]

  @moduledoc """
  This module contains functions for making multi-key calls.

  Each multi-key callback is executed in a separate process, which is
  responsible for collecting the values, invoking callback, returning the
  result, and handling the timeout and possible errors. Computation can start
  after all the related values will be known. If a call is a value-changing
  (`get_and_update/4`, `update/4`, `cast/4`), for every involved `key` will be
  created worker and a special "return me a value and wait for a new one"
  request will be added to the end of the workers queue.

  When performing `get/4` with option `!: true`, values are fetched immediately,
  without sending any requests and creating workers. If `!: false` option (by
  default) is given, no workers will be created and special "return me a value"
  request will be added to the end of the workers queue.
  """

  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "`AgentMap` server (name, link, pid, …)"
  @type agentmap :: pid | {atom, node} | name | %AgentMap{}
  @type am :: agentmap

  @type key :: term
  @type value :: term

  defp _cast(agentmap, req, opts) do
    GenServer.cast(pid(agentmap), struct(req, opts))
    agentmap
  end

  ##
  ## PUBLIC PART
  ##

  @doc """
  Computes the `fun`, using `keys` values in the `agentmap` as an argument.

  The `fun` is sent to the `agentmap` which invokes it, passing the list of
  values associated with the `keys` (`nil`s for missing keys). The result of the
  invocation is returned.

  For example, `get(account, [:Alice, :Bob], &Enum.sum/1)` call returns the sum
  of the account balances of Alice and Bob. Suppose that `:Alice` has a worker
  that holds a queue of callbacks. Some of this callbacks will change the amount
  of money she has, and some will make calculations using this information. This
  call will create a special temporary process responsible for the multi-key
  call. It will take value stored for `:Bob` and add a special get-request to
  the end of the `:Alice`'s worker queue. After this request will be fulfilled,
  `Enum.sum/1` will be called, passing the amount of money `:Alice` and `:Bob`
  has as a single list argument.

  ## Options

    * `!: true` — (`boolean`, `false`) if given, `fun` will be executed
      immediately, passing current values as an argument.

      To achieve the same on the client side use:

          for key <- keys do
            case AgentMap.fetch(agentmap, key) do
              {:ok, value} ->
                value

              :error ->
                nil
            end
          end
          |> fun.()

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout
      section](AgentMap.html#module-timeout);

    * `timeout: {:break, pos_integer}` — to throw out from queue or cancel a
      running call upon the occurence of a timeout. See [timeout
      section](AgentMap.html#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`).

  ## Special process dictionary keys

  One can use `:"$keys"` and `:"$map"` keys:

      iex> alias AgentMap.Multi, as: M
      iex> am = AgentMap.new(a: nil, b: 42)
      iex> M.get(am, [:a, :b, :c], fn _ ->
      ...>   Process.get(:"$keys")
      ...> end)
      [:a, :b, :c]
      #
      iex> M.get(am, [:a, :b, :c], fn [nil, 42, nil] ->
      ...>   Process.get(:"$map")
      ...> end)
      %{a: nil, b: 42}

  ## Examples

      iex> alias AgentMap.Multi, as: M
      iex> am = AgentMap.new()
      iex> M.update(am, [:Alice, :Bob], [42, 43])
      iex> M.get(am, [:Alice, :Bob], fn [a, b] ->
      ...>   a - b
      ...> end)
      -1
      # Order matters:
      iex> M.get(am, [:Bob, :Alice], fn [b, a] ->
      ...>   b - a
      ...> end)
      1

   "Priority" calls:

      iex> alias AgentMap.Multi, as: M
      iex> import :timer
      iex> am = AgentMap.new(key: 42)
      iex> AgentMap.cast(am, :key, fn _ -> sleep(10); 43 end)
      iex> M.get(am, [:key], & &1, !: true)
      [42]
      iex> am.key # the same
      42
      iex> M.get(am, [:key], & &1, !: false)
      [43]
      # — executed in 10 ms.
      iex> am.key
      43
  """
  @spec get(am, [key], ([value] -> get), keyword) :: get when get: var
  def get(agentmap, keys, fun, opts \\ [!: false, timeout: 5000])
      when is_function(fun, 1) and is_list(keys) do
    req = %Req{action: :get, keys: keys, fun: fun}
    _call(agentmap, req, opts)
  end

  @doc """
  Updates `keys` values and returnes "get"-value, all in one pass.

  The `fun` is sent to the `agentmap` which invokes it, passing the list of
  values associated with `keys` (`nil`s for missing keys) as an argument. The
  `fun` must produce "get"-value and a new values list for `keys`. For example,
  `get_and_update(account, [:Alice, :Bob], fn [a,b] -> {:swapped, [b,a]} end)`
  produces `:swapped` "get"-value and swaped Alice's and Bob's balances as an
  updated values.

  See the [begining of this docs](#content) for the details of processing.

  Callback (`fun`) can return:

    * a list with values `[{"get"-value, new value} | {"get"-value} | :id | :pop]`.
      This returns a list of "get"-values. For ex.:

          iex> alias AgentMap.Multi, as: M
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> M.get_and_update(am, keys, fn _ ->
          ...>   [{:get, :new_value}, {:get}, :pop, :id]
          ...> end)
          [:get, :get, 3, nil]
          iex> AgentMap.take(am, keys)
          %{a: :new_value, b: 2}

    * a tuple `{"get" value, [new value] | :id | :drop}`.
      For ex.:

          iex> alias AgentMap.Multi, as: M
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> M.get_and_update(am, keys, fn _ ->
          ...>   {:get, [4, 3, 2, 1]}
          ...> end)
          :get
          iex> AgentMap.take(am, keys)
          %{a: 4, b: 3, c: 2, d: 1}
          iex> M.get_and_update(am, keys, fn _ ->
          ...>   {:get, :id}
          ...> end)
          :get
          iex> AgentMap.take(am, keys)
          %{a: 4, b: 3, c: 2, d: 1}
          # — no changes.
          iex> M.get_and_update(am, [:b, :c], fn _ ->
          ...>   {:get, :drop}
          ...> end)
          :get
          iex> AgentMap.take(am, keys)
          %{a: 4, d: 1}

    * a one element tuple `{"get" value}`, that is an alias for the `{"get"
      value, :id}`.
      For ex.:

          iex> alias AgentMap.Multi, as: T
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> M.get_and_update(am, keys, fn _ -> {:get} end)
          :get
          iex> AgentMap.take(am, keys)
          %{a: 1, b: 2, c: 3}
          # — no changes.

    * `:id` to return list of values while not changing them.
      For ex.:

          iex> alias AgentMap.Multi, as: M
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> M.get_and_update(am, keys, fn _ -> :id end)
          [1, 2, 3, nil]
          iex> AgentMap.take(am, keys)
          %{a: 1, b: 2, c: 3}
          # — no changes.

    * `:pop` to return values while removing them from `agentmap`.
      For ex.:

          iex> alias AgentMap.Multi, as: M
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> M.get_and_update(am, keys, fn _ -> :pop end)
          [1, 2, 3, nil]
          iex> AgentMap.take(am, keys)
          %{}

  Multis are *Isolated* and *Durabled* (by ACID model). *Atomicity* can be
  implemented inside callbacks and *Consistency* is out of question here as it
  is the application level concept.

  ## Special process dictionary keys

  One can use `:"$keys"` and `:"$map"` keys:

      iex> alias AgentMap.Multi, as: M
      iex> am = AgentMap.new(a: nil, b: 42)
      iex> M.get_and_update(am, [:a, :b, :c], fn _ ->
      ...>   keys = Process.get(:"$keys")
      ...>   map = Process.get(:"$map")
      ...>   {keys, map}
      ...> end)
      {[:a, :b, :c], %{a: nil, b: 42}}

  ## Options

    * `!: true` — (`boolean`, `false`) to make
      [priority](AgentMap.html#module-priority-calls-true) multi-key calls.

      Asks involved workers via "selective receive" to process "return me a
      value and wait for a new one" [request](#content) in a prioriry order.

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout
      section](#AgentMap.html#module-timeout);

    * `timeout: {:break, pos_integer}` — to throw out from queue or cancel a
      running call upon the occurence of a timeout. See [timeout
      section](AgentMap.html#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`).

  ## Examples

      iex> alias AgentMap.Multi, as: M
      iex> %{Alice: 42, Bob: 24}
      ...> |> AgentMap.new()
      ...> |> M.get_and_update([:Alice, :Bob], fn [a, b] ->
      ...>      if a > 10 do
      ...>        a = a - 10
      ...>        b = b + 10
      ...>        [{a, a}, {b, b}] # [{get, new_state}]
      ...>      else
      ...>        {{:error, "Alice does not have 10$ to give to Bob!"}, [a, b]} # {get, [new_state]}
      ...>      end
      ...>    end)
      [32, 34]

  or:

      iex> alias AgentMap.Multi, as: M
      iex> am = AgentMap.new(Alice: 42, Bob: 24)
      iex> M.get_and_update(am, [:Alice, :Bob], fn _ ->
      ...>   [:pop, :id]
      ...> end)
      [42, 24]
      iex> M.get(am, [:Alice, :Bob], & &1)
      [nil, 24]

  (!) Value changing transactions (`get_and_update/4`, `update/4`, `cast/4`)
  will block execution for all the involving `keys`. For ex.:

      iex> import :timer
      iex> %{Alice: 42, Bob: 24, Chris: 0}
      ...> |> AgentMap.new()
      ...> |> AgentMap.get_and_update([:Alice, :Bob], fn _ >
      ...>   sleep(10) && {"10 ms later"}
      ...> end)
      "10 ms later"

  will delay for `10` ms any execution of the (single key or multi-key)
  `get_and_update/4`, `update/4`, `cast/4` or `get/4` (`!: false`) calls that
  involves `:Alice` and `:Bob` keys . Priority calls that are not changing
  values will not be delayed. `:Chris` key is not influenced.

      iex> alias AgentMap.Multi, as: M
      iex> am = AgentMap.new(a: 22, b: 24)
      iex> M.get_and_update(am, [:a, :b], fn [u, d] ->
      ...>   [{u, d}, {d, u}]
      ...> end)
      [22, 24]
      iex> M.get(am, [:a, :b], & &1)
      [24, 22]
      #
      iex> M.get_and_update(am, [:b, :c, :d], fn _ ->
      ...>   [:pop, {42, 42}, {44, 44}]
      ...> end)
      [22, 42, 44]
      iex> AgentMap.has_key?(am, :b)
      false
      #
      iex> keys = [:a, :b, :c, :d]
      iex> M.get_and_update(am, keys, fn _ ->
      ...>   [:id, {nil, :_}, {:_, nil}, :pop]
      ...> end)
      [24, nil, :_, 44]
      iex> M.get(am, keys, & &1)
      [24, :_, nil, nil]
  """

  @typedoc """
  Callback that is used for a multi-key call.
  """
  @type cb_m(get) ::
          ([value] ->
             {get}
             | {get, [value] | :drop | :id}
             | [{any} | {any, value} | :pop | :id]
             | :pop
             | :id)
  @spec get_and_update(am, [key], cb_m(get), keyword) :: get | [value]
        when get: var
  def get_and_update(agentmap, keys, fun, opts \\ [!: false, timeout: 5000])
      when is_function(fun, 1) and is_list(keys) do
    unless keys == Enum.uniq(keys) do
      raise """
            expected uniq keys for `update`, `get_and_update` and
            `cast` transactions. Got: #{inspect(keys)}. Please
            check #{inspect(keys -- Enum.uniq(keys))}.
            """
            |> String.replace("\n", " ")
    end

    req = %Req{action: :get_and_update, keys: keys, fun: fun}
    _call(agentmap, req, opts)
  end

  @doc """
  Updates the `keys` of the `agentmap` with the given `fun` in one go.

  After the `fun` is executed, returns the `agentmap` argument unchanged to
  support piping.

  This call is no more than a syntax sugar for `get_and_update(am, keys, &{am,
  fun.(&1)}, opts)`.

  Multial `fun` can return:

    * a list of new values;
    * `:id` — instructs to leave values as they are;
    * `:drop`.

  ## Options

  The same as for `get_and_update/4`.

  ## Examples

  To swap the balances of Alice and Bob:

      update(account, fn [a,b] -> [b,a] end, [:Alice, :Bob])

  More:

      iex> alias AgentMap.Multi, as: M
      iex> am = AgentMap.new(a: 42, b: 24, c: 33, d: 51)
      iex> M.get(am, [:a, :b, :c, :d], & &1)
      [42, 24, 33, 51]
      iex> am
      ...> |> M.update([:a, :b], &Enum.reverse/1)
      ...> |> M.get([:a, :b, :c, :d], & &1)
      [24, 42, 33, 51]
      iex> am
      ...> |> M.update([:a, :b], fn _ -> :drop end)
      ...> |> AgentMap.keys()
      [:c, :d]
      iex> am
      ...> |> M.update([:c], fn _ -> :drop end)
      ...> |> AgentMap.update(:d, fn _ -> :drop end)
      ...> |> M.get([:c, :d], & &1)
      [nil, :drop]
  """
  @spec update(am, ([value] -> [value] | :drop | :id), [key], keyword) :: am
  def update(agentmap, keys, fun, opts \\ [!: false, timeout: 5000])
      when is_function(fun, 1) and is_list(keys) do
    get_and_update(agentmap, keys, &{agentmap, fun.(&1)}, opts)
  end

  @doc """
  Performs "fire and forget" `update/4` call, using `GenServer.cast/2`.

  Immediately returns the `agentmap` argument unchanged to support piping.

  ## Special process dictionary keys

  Are the same as for `get_and_update/4`.

  ## Options

  Are the same as for `get_and_update/4`, except for the `timeout: pos_integer`.
  """
  @spec cast(am, ([value] -> [value]), [key], keyword) :: am
  @spec cast(am, ([value] -> :drop | :id), [key], keyword) :: am
  def cast(agentmap, keys, fun, opts \\ [!: false]) when is_function(fun, 1) and is_list(keys) do
    req = %Req{action: :get_and_update, keys: keys, fun: &{:_get, fun.(&1)}}
    _cast(agentmap, req, opts)
  end
end

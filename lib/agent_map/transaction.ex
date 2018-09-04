defmodule AgentMap.Transaction do
  @moduledoc """
  This module contains functions for making transactional calls.

  Each transaction is executed in a separate process, which is responsible for
  collecting the values, invoking the callback, returning the result, and
  handling the timeout. Computation can start after all the related values will
  be known. If transaction call is a value-changing (`get_and_update/4`,
  `update/4`, `cast/4`), for every involved `key` will be created worker and
  special "return me a value and wait for a new one" request will be added to
  the end of the workers queue.

  When performing `get/4` with option `!: true`, values are fetched immediately,
  without sending any requests and creating workers. If `!: false` option (by
  default) is given, no workers will be created and special "return me a value"
  request will be added to the end of the workers queue.
  """

  alias AgentMap.{Common, Req, CallbackError}

  import Common, only: [run: 2, to_ms: 1, reply: 2, get: 2, handle_timeout_error: 2]
  import Req, only: [get_value: 2, timeout: 1]
  import System, only: [system_time: 0]

  require Logger

  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "`AgentMap` server (name, link, pid, …)"
  @type agentmap :: pid | {atom, node} | name | %AgentMap{}
  @type am :: agentmap

  @type key :: term
  @type value :: term

  ##
  ## HELPERS
  ##

  defp share(to: t) do
    k = Process.get(:"$key")
    v = Process.get(:"$value")
    send(t, {k, v})
  end

  defp accept() do
    receive do
      :drop ->
        :pop

      :id ->
        :id

      {:value, v} ->
        {:_, v}
    end
  end

  ##
  ## STAGES: prepair → collect → run → finalize
  ##

  defp worker?(key, state) do
    match?({:pid, _}, get(state, key))
  end

  defp prepair(%{action: :get, !: true}, state) do
    # do nothing
    state
  end

  defp prepair(%{action: :get} = req, state) do
    {_, keys} = req.data

    s = self()

    fun = fn _ ->
      share(to: s)
    end

    req = %{req | timeout: :infinity}

    for key <- keys, worker?(key, state) do
      Req.handle(%{req | data: {key, fun}}, state)
    end

    state
  end

  defp prepair(%{action: :get_and_update} = req, state) do
    {_, keys} = req.data

    s = self()

    fun = fn _ ->
      share(to: s)
      accept()
    end

    req = %{req | timeout: :infinity}

    Enum.reduce(keys, state, fn key, state ->
      Req.handle(%{req | data: {key, fun}}, state)
    end)
  end

  defp collect(%{action: :get, !: true} = req, state) do
    {_, keys} = req.data

    for key <- keys do
      {key, get_value(key, state)}
    end
  end

  defp collect(req, state) do
    {_, keys} = req.data

    known =
      for key <- keys, not worker?(key, state), into: %{} do
        {key, get_value(key, state)}
      end

    passed = to_ms(system_time() - req.inserted_at)

    if timeout(req) > passed do
      unknown = keys -- Map.keys(known)
      _collect(known, unknown, timeout(req) - passed)
    else
      {:error, :expired}
    end
  end

  defp _collect(known, [], _), do: {:ok, known}

  defp _collect(known, unknown, timeout) do
    now = system_time()

    receive do
      {key, value} ->
        passed = to_ms(system_time() - now)
        timeout = timeout - passed

        known =
          case value do
            {:value, v} ->
              Map.put(known, key, v)

            nil ->
              known
          end

        _collect(known, unknown -- [key], timeout)
    after
      timeout ->
        {:error, :expired}
    end
  end

  defp broadcast(keys, msg, state) do
    for key <- keys do
      {:pid, worker} = get(state, key)
      send(worker, msg)
    end
  end

  defp commit(%{action: :get}, _, _, _), do: :nothing

  defp commit(%{action: :get_and_update} = req, values, result, state) do
    {_, keys} = req

    case result do
      :pop ->
        broadcast(keys, :drop, state)
        {:ok, values}

      :id ->
        broadcast(keys, :id, state)
        {:ok, values}

      {get, :id} ->
        broadcast(keys, :id, state)
        {:ok, get}

      {get, :drop} ->
        broadcast(keys, :id, state)
        {:ok, get}

      {get, values} when length(values) == length(keys) ->
        for {key, value} <- Enum.zip(keys, values) do
          {:pid, worker} = get(state, key)
          send(worker, value)
        end

        {:ok, get}

      {_, values} ->
        {:error, {:update, values}}

      {get} ->
        broadcast(keys, :id, state)
        {:ok, get}

      lst when is_list(lst) and length(lst) == length(keys) ->
        get =
          for {key, ret} <- Enum.zip(keys, lst) do
            get = get_value(key, state)

            case ret do
              {get, v} ->
                {:pid, worker} = get(state, key)
                send(worker, v)
                get

              {get} ->
                {:pid, worker} = get(state, key)
                send(worker, :id)
                get

              :id ->
                {:pid, worker} = get(state, key)
                send(worker, :id)
                get

              :pop ->
                {:pid, worker} = get(state, key)
                send(worker, :drop)
                get
            end
          end

        {:ok, {:get, get}}

      _err ->
        {:error, {:callback, result}}
    end
  end

  ##
  ## MULTIPLE KEY HANDLERS
  ##

  ##
  ## (prepair) → (collect)
  ## → (Common.run) in a separate Task
  ## → (commit) → (Common.reply)
  ##

  @doc false
  def handle(req, state) do
    {_, keys} = req.data

    Task.start_link(fn ->
      state = prepair(req, state)

      case collect(req, state) do
        {:ok, known} ->
          Task.async(fn ->
            Process.put(:"$map", known)
            Process.put(:"$keys", keys)
            values = Enum.map(keys, &known[&1])

            with {:ok, result} <- run(req, values),
                 {:ok, get} <- commit(req, values, result, state) do
              reply(req.from, get)
            else
              {:error, {:callback, result}} ->
                raise CallbackError, got: result

              {:error, {:update, values}} ->
                raise CallbackError, len: length(values)

              {:error, :expired} ->
                handle_timeout_error(req, keys)

                for key <- keys do
                  {:pid, worker} = get(state, key)
                  send(worker, :id)
                end
            end
          end)

        {:error, :expired} ->
          handle_timeout_error(req, keys)
      end

      {:noreply, state}
    end)
  end

  ##
  ## PUBLIC PART
  ##

  @doc """
  Computes the `fun`, using `keys` values in the `agentmap` as an argument.

  The `fun` is sent to the `agentmap` which invokes it, passing the list of
  values associated with `keys` (`nil`s for missing keys). The result of the
  invocation is returned.

  For example, `get(account, [:Alice, :Bob], &Enum.sum/1)` call returns the sum
  of the account balances of Alice and Bob. Suppose that `:Alice` has a worker
  that holds a queue of callbacks. Some of this callbacks will change the amount
  of money she has, and some will make calculations using this information. This
  call will create a special temporary process responsible for the transaction.
  It will take value stored for `:Bob` and add a special get-request to the end
  of the `:Alice`'s worker queue. After this request will be fulfilled,
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

      iex> alias AgentMap.Transaction, as: T
      iex> am = AgentMap.new(a: nil, b: 42)
      iex> T.get(am, [:a, :b, :c], fn _ ->
      ...>   Process.get(:"$keys")
      ...> end)
      [:a, :b, :c]
      #
      iex> T.get(am, [:a, :b, :c], fn [nil, 42, nil] ->
      ...>   Process.get(:"$map")
      ...> end)
      %{a: nil, b: 42}

  ## Examples

      iex> alias AgentMap.Transaction, as: T
      iex> am = AgentMap.new()
      iex> T.update(am, [:Alice, :Bob], [42, 43])
      iex> T.get(am, [:Alice, :Bob], fn [a, b] ->
      ...>   a - b
      ...> end)
      -1
      # Order matters:
      iex> T.get(am, [:Bob, :Alice], fn [b, a] ->
      ...>   b - a
      ...> end)
      1

   "Priority" calls:

      iex> alias AgentMap.Transaction, as: T
      iex> import :timer
      iex> am = AgentMap.new(key: 42)
      iex> AgentMap.cast(am, :key, fn _ -> sleep(10); 43 end)
      iex> T.get(am, [:key], & &1, !: true)
      [42]
      iex> am.key # the same
      42
      iex> T.get(am, [:key], & &1, !: false)
      [43]
      # — executed in 10 ms.
      iex> am.key
      43
  """
  @spec get(am, [key], ([value] -> get), keyword) :: get when get: var
  def get(agentmap, keys, fun, opts) when is_function(fun, 1) and is_list(keys) do
    req = %Req{action: :get, data: {fun, keys}}
    AgentMap._call(agentmap, req, opts)
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

  Transaction callback (`fun`) can return:

    * a list with values `[{"get"-value, new value} | {"get"-value} | :id | :pop]`.
      This returns a list of "get"-values. For ex.:

          iex> alias AgentMap.Transaction, as: T
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> T.get_and_update(am, keys, fn _ ->
          ...>   [{:get, :new_value}, {:get}, :pop, :id]
          ...> end)
          [:get, :get, 3, nil]
          iex> AgentMap.take(am, keys)
          %{a: :new_value, b: 2}

    * a tuple `{"get" value, [new value] | :id | :drop}`.
      For ex.:

          iex> alias AgentMap.Transaction, as: T
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> T.get_and_update(am, keys, fn _ ->
          ...>   {:get, [4, 3, 2, 1]}
          ...> end)
          :get
          iex> AgentMap.take(am, keys)
          %{a: 4, b: 3, c: 2, d: 1}
          iex> T.get_and_update(am, keys, fn _ ->
          ...>   {:get, :id}
          ...> end)
          :get
          iex> AgentMap.take(am, keys)
          %{a: 4, b: 3, c: 2, d: 1}
          # — no changes.
          iex> T.get_and_update(am, [:b, :c], fn _ ->
          ...>   {:get, :drop}
          ...> end)
          :get
          iex> AgentMap.take(am, keys)
          %{a: 4, d: 1}

    * a one element tuple `{"get" value}`, that is an alias for the `{"get"
      value, :id}`.
      For ex.:

          iex> alias AgentMap.Transaction, as: T
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> T.get_and_update(am, keys, fn _ -> {:get} end)
          :get
          iex> AgentMap.take(am, keys)
          %{a: 1, b: 2, c: 3}
          # — no changes.

    * `:id` to return list of values while not changing them.
      For ex.:

          iex> alias AgentMap.Transaction, as: T
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> T.get_and_update(am, keys, fn _ -> :id end)
          [1, 2, 3, nil]
          iex> AgentMap.take(am, keys)
          %{a: 1, b: 2, c: 3}
          # — no changes.

    * `:pop` to return values while removing them from `agentmap`.
      For ex.:

          iex> alias AgentMap.Transaction, as: T
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> keys = [:a, :b, :c, :d]
          iex> T.get_and_update(am, keys, fn _ -> :pop end)
          [1, 2, 3, nil]
          iex> AgentMap.take(am, keys)
          %{}

  Transactions are *Isolated* and *Durabled* (by ACID model). *Atomicity* can be
  implemented inside callbacks and *Consistency* is out of question here as it
  is the application level concept.

  ## Special process dictionary keys

  One can use `:"$keys"` and `:"$map"` keys:

      iex> alias AgentMap.Transaction, as: T
      iex> am = AgentMap.new(a: nil, b: 42)
      iex> T.get_and_update(am, [:a, :b, :c], fn _ ->
      ...>   keys = Process.get(:"$keys")
      ...>   map = Process.get(:"$map")
      ...>   {keys, map}
      ...> end)
      {[:a, :b, :c], %{a: nil, b: 42}}

  ## Options

    * `!: true` — (`boolean`, `false`) to make
      [priority](AgentMap.html#module-priority-calls-true) transactional calls.

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

      iex> alias AgentMap.Transaction, as: T
      iex> %{Alice: 42, Bob: 24}
      ...> |> AgentMap.new()
      ...> |> T.get_and_update([:Alice, :Bob], fn [a, b] ->
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

      iex> alias AgentMap.Transaction, as: T
      iex> am = AgentMap.new(Alice: 42, Bob: 24)
      iex> T.get_and_update(am, [:Alice, :Bob], fn _ ->
      ...>   [:pop, :id]
      ...> end)
      [42, 24]
      iex> T.get(am, [:Alice, :Bob], & &1)
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

  will delay for `10` ms any execution of the (single key or transactional)
  `get_and_update/4`, `update/4`, `cast/4` or `get/4` (`!: false`) calls that
  involves `:Alice` and `:Bob` keys . Priority calls that are not changing
  values will not be delayed. `:Chris` key is not influenced.

      iex> alias AgentMap.Transaction, as: T
      iex> am = AgentMap.new(a: 22, b: 24)
      iex> T.get_and_update(am, [:a, :b], fn [u, d] ->
      ...>   [{u, d}, {d, u}]
      ...> end)
      [22, 24]
      iex> T.get(am, [:a, :b], & &1)
      [24, 22]
      #
      iex> T.get_and_update(am, [:b, :c, :d], fn _ ->
      ...>   [:pop, {42, 42}, {44, 44}]
      ...> end)
      [22, 42, 44]
      iex> AgentMap.has_key?(am, :b)
      false
      #
      iex> keys = [:a, :b, :c, :d]
      iex> T.get_and_update(am, keys, fn _ ->
      ...>   [:id, {nil, :_}, {:_, nil}, :pop]
      ...> end)
      [24, nil, :_, 44]
      iex> T.get(am, keys, & &1)
      [24, :_, nil, nil]
  """

  @typedoc """
  Callback that is used for a transactional call.
  """
  @type cb_t(get) ::
          ([value] ->
             {get}
             | {get, [value] | :drop | :id}
             | [{any} | {any, value} | :pop | :id]
             | :pop
             | :id)
  @spec get_and_update(am, [key], cb_t(get), keyword) :: get | [value]
        when get: var
  def get_and_update(agentmap, keys, fun, opts) when is_function(fun, 1) and is_list(keys) do
    unless keys == Enum.uniq(keys) do
      raise """
            expected uniq keys for `update`, `get_and_update` and
            `cast` transactions. Got: #{inspect(keys)}. Please
            check #{inspect(keys -- Enum.uniq(keys))} keys.
            """
            |> String.replace("\n", " ")
    end

    req = %Req{action: :get_and_update, data: {fun, keys}}
    AgentMap._call(agentmap, req, opts)
  end

  @doc """
  Updates the `keys` of the `agentmap` with the given `fun` in one go.

  After the `fun` is executed, returns the `agentmap` argument unchanged to
  support piping.

  This call is no more than a syntax sugar for `get_and_update(am, keys, &{am,
  fun.(&1)}, opts)`.

  Transactional `fun` can return:

    * a list of new values;
    * `:id` — instructs to leave values as they are;
    * `:drop`.

  ## Options

  The same as for `get_and_update/4`.

  ## Examples

  To swap the balances of Alice and Bob:

      update(account, fn [a,b] -> [b,a] end, [:Alice, :Bob])

  More:

      iex> alias AgentMap.Transaction, as: T
      iex> am = new(a: 42, b: 24, c: 33, d: 51)
      iex> T.get(am, [:a, :b, :c, :d], & &1)
      [42, 24, 33, 51]
      iex> am
      ...> |> T.update([:a, :b], &Enum.reverse/1)
      ...> |> T.get([:a, :b, :c, :d], & &1)
      [24, 42, 33, 51]
      iex> am
      ...> |> T.update([:a, :b], fn _ -> :drop end)
      ...> |> AgentMap.keys()
      [:c, :d]
      iex> am
      ...> |> T.update([:c], fn _ -> :drop end)
      ...> |> AgentMap.update(:d, fn _ -> :drop end)
      ...> |> T.get([:c, :d], & &1)
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
    req = %Req{action: :get_and_update, data: {fun, keys}}
    AgentMap._call(agentmap, req, opts)
  end
end

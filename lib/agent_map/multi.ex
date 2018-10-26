defmodule AgentMap.Multi do
  alias AgentMap.Multi.Req

  import AgentMap, only: [_call: 3, _prep: 2]

  @moduledoc """
  This module contains functions for making multi-key calls.

  Each multi-key callback is executed in a separate process, which is
  responsible for collecting values, invoking callback, returning a result, and
  handling timeout and possible errors. Computation can start after all the
  related values will be known. If a call is a value-changing
  (`get_and_update/4`, `update/4`, `cast/4`), for every involved `key` will be
  created worker and a special "return me a value and wait for a new one"
  request will be added to the end of the workers queue.

  When performing `get/4` with option `!: :now`, values are fetched immediately,
  without sending any requests and creating workers.
  """

  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "`AgentMap` server (name, link, pid, …)"
  @type am :: pid | {atom, node} | name | %AgentMap{}

  @type key :: term
  @type value :: term

  ##
  ## PUBLIC PART
  ##

  @doc """
  Gets a values via the given `fun`.

  The `fun` is sent to an instance of `AgentMap` which invokes it, passing the
  values associated with the `keys` (`nil`s for missing keys). The result of the
  invocation is returned from this function.

  ## Options

    * `:initial` (`term`, `nil`) — to set the initial value for missing keys;

    * `:!` (`priority`, :avg) — to set
      [priority](AgentMap.html#module-priority);

    * `!: :now` — to use current values for this call.

    * `timeout: {:!, pos_integer}` — to not execute this call after
      [timeout](AgentMap.html#module-timeout);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

  To sum balances of Alice and Bob:

      get(account, [:Alice, :Bob], &Enum.sum/1)

  #

      iex> %{Alice: 42}
      ...> |> AgentMap.new()
      ...> |> get([:Alice, :Bob], & &1, initial: 0)
      [42, 0]

      iex> AgentMap.new()
      ...> |> update([:Alice, :Bob], fn _ -> [43, 42] end)
      ...> |> get([:Alice, :Bob], fn [a, b] -> a - b end)
      1

      iex> AgentMap.new(a: 1, b: 1)
      ...> |> AgentMap.sleep(:a, 20)
      ...> |> AgentMap.put(:a, 2)
      ...> |> get([:a, :b], & &1, !: :now)
      [1, 1]
  """
  @spec get(am, [key], ([value] -> get), keyword | timeout) :: get when get: var
  def get(am, keys, fun, opts \\ [!: :avg]) do
    opts = _prep(opts, !: :avg)
    req = %Req{act: :get, keys: keys, fun: fun, data: opts[:initial]}

    _call(am, req, opts)
  end

  @doc """
  Returns the values for the given `keys`.

  Syntactic sugar for `get(am, keys, & &1, !: :min)`.

  This call executed with a minimum (`0`) priority. As so, execution will start
  only after all other calls for all the related `keys` are completed.

  See `get/4`.

  ## Examples

      iex> am = AgentMap.new(Alice: 42)
      iex> get(am, [:Alice, :Bob])
      [42, nil]

      iex> %{Alice: 42, Bob: 42}
      ...> |> AgentMap.new()
      ...> |> AgentMap.sleep(:Alice, 10)
      ...> |> AgentMap.put(:Alice, 0)
      ...> |> get([:Alice, :Bob])
      [0, 42]
  """
  @spec get(am, [key]) :: [value | nil]
  def get(am, keys), do: get(am, keys, & &1, !: :min, timeout: 4999)

  @doc """
  Gets the values for `keys` and updates it, all in one pass.

  The `fun` is sent to an `AgentMap` that invokes it, passing the values for
  `keys` (`nil`s for missing values). This `fun` must produce "get"-value and a
  new values list for `keys`. For example, `get_and_update(account, [:Alice,
  :Bob], fn [a,b] -> {:swapped, [b,a]} end)` produces `:swapped` "get"-value
  while swapes Alice's and Bob's balances.

  A `fun` can return:

    * a list with values `[{"get"-value, new value} | {"get"-value} | :id | :pop]`.
      This returns a list of "get"-values. For ex.:

          iex> keys = [:a, :b, :c, :d]
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> get_and_update(am, keys, fn _ ->
          ...>   [{:get, :new_value}, {:get}, :pop, :id]
          ...> end)
          [:get, :get, 3, nil]
          iex> get(am, keys)
          [:new_value, 2, nil, nil]

    * a tuple `{"get"-value, [new value] | :id | :drop}`.
      For ex.:

          iex> keys = [:a, :b, :c, :d]
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> get_and_update(am, keys, fn _ ->
          ...>   {:get, [4, 3, 2, 1]}
          ...> end)
          :get
          iex> get(am, keys)
          [4, 3, 2, 1]
          #
          iex> get_and_update(am, keys, fn _ ->
          ...>   {:get, :id}
          ...> end)
          :get
          iex> get(am, keys)
          [4, 3, 2, 1]
          #
          iex> get_and_update(am, [:b, :c], fn _ ->
          ...>   {:get, :drop}
          ...> end)
          :get
          iex> get(am, keys)
          [4, nil, nil, 1]

    * a one element tuple `{"get"-value}`, that is an alias for the `{"get"
      value, :id}`.
      For ex.:

          iex> keys = [:a, :b, :c, :d]
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> get_and_update(am, keys, fn _ -> {:get} end)
          :get
          iex> get(am, keys)
          [1, 2, 3, nil]
          # — no changes.

    * `:id` to return list of values while not changing them.
      For ex.:

          iex> keys = [:a, :b, :c, :d]
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> get_and_update(am, keys, fn _ -> :id end)
          [1, 2, 3, nil]
          iex> get(am, keys)
          [1, 2, 3, nil]
          # — no changes.

    * `:pop` to return values while removing them from `agentmap`.
      For ex.:

          iex> keys = [:a, :b, :c, :d]
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> get_and_update(am, keys, fn _ -> :pop end)
          [1, 2, 3, nil]
          iex> get(am, keys)
          [nil, nil, nil, nil]

  ## Options

    * `:initial` (`term`, `nil`) — if value does not exist it is considered to
      be the one given as initial;

    * `:!` (`priority`, `:avg`) — to set
      [priority](AgentMap.html#module-priority);

    * `timeout: {:!, pos_integer}` — to not execute callback after the
      [timeout](AgentMap.hmtl#module-timeout);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> am = AgentMap.new(Alice: 42, Bob: 24)
      ...>
      iex> get_and_update(am, [:Alice, :Bob], fn [a, b] ->
      ...>   if a > 10 do
      ...>     a = a - 10
      ...>     b = b + 10
      ...>     [{a, a}, {b, b}] # [{get, new_state}]
      ...>   else
      ...>     {{:error, "Alice does not have 10$ to give to Bob!"}, [a, b]} # {get, [new_state]}
      ...>   end
      ...> end)
      [32, 34]

  #

      iex> am = AgentMap.new(Alice: 42, Bob: 24)
      ...>
      iex> get_and_update(am, [:Alice, :Bob], fn _ ->
      ...>   [:pop, :id]
      ...> end)
      [42, 24]
      iex> get(am, [:Alice, :Bob])
      [nil, 24]

  (!) Value-changing calls (`get_and_update/4`, `update/4`, `cast/4`) will block
  execution for all the involving `keys`. For ex.:

      iex> am = AgentMap.new(Alice: 42, Bob: 24, Chris: 0)
      ...>
      iex> am
      ...> |> cast([:Alice, :Bob], fn _ -> sleep(10); :id end)
      ...> |> get([:Chris], fn _ -> "now" end)
      "now"
      iex> am
      ...> |> get([:Chris, :Bob], fn _ -> "10 ms later" end)
      "10 ms later"

  will delay for `10` ms any execution involved `:Alice` or `:Bob` keys.
  `:Chris` key is not influenced.

      iex> am = AgentMap.new(a: 1, b: 2)
      ...>
      iex> get_and_update(am, [:a, :b], fn [u, d] ->
      ...>   [{u, d}, {d, u}]
      ...> end)
      [1, 2]
      iex> get(am, [:a, :b])
      [2, 1]

      iex> keys = [:a, :b, :c, :d]
      iex> am = AgentMap.new(a: 1, b: 2)
      ...>
      iex> get_and_update(am, keys, fn _ ->
      ...>   [:id, :pop, {3, 0}, {4, 0}]
      ...> end)
      [1, 2, 3, 4]
      iex> get(am, keys)
      [1, nil, 0, 0]

      iex> am = AgentMap.new(a: 1)
      ...>
      iex> get_and_update(am, [:a, :b], fn [1, 1] ->
      ...>   {"get", [2, 2]}
      ...> end, initial: 1)
      "get"
      #
      iex> get_and_update(am, [:a, :b], fn [2, 2] ->
      ...>   {"get", :drop}
      ...> end)
      "get"
      iex> get(am, [:a, :b])
      [nil, nil]
  """

  @typedoc """
  Callback for multi-key call.
  """
  @type cb_m(get) ::
          ([value] ->
             {get}
             | {get, [value] | :drop | :id}
             | [{any} | {any, value} | :pop | :id]
             | :pop
             | :id)

  @spec get_and_update(am, [key], cb_m(get), keyword | timeout) :: get | [value]
        when get: var
  def get_and_update(am, keys, fun, opts \\ []) do
    unless keys == Enum.uniq(keys) do
      raise """
            expected uniq keys for `update`, `get_and_update` and
            `cast` multi-key calls. Got: #{inspect(keys)}. Please
            check #{inspect(keys -- Enum.uniq(keys))}.
            """
            |> String.replace("\n", " ")
    end

    opts = _prep(opts, !: :avg)
    req = %Req{act: :get_and_update, keys: keys, fun: fun, data: opts[:initial]}

    _call(am, req, opts)
  end

  @doc """
  Updates `keys` with the given `fun`.

  Syntactic sugar for `get_and_update(am, keys, &{am, fun.(&1)}, opts)`. As so,
  callback (`fun`) can return:

    * a list of new values;
    * `:id` — instructs to leave values as they are;
    * `:drop` — instructs to drop `keys`.

  See `get_and_update/4`.

  ## Options

    * `:initial` (`term`, `nil`) — if value does not exist it is considered to
      be the one given as initial;

    * `:!` (`priority`, `:avg`) — to set
      [priority](AgentMap.html#module-priority);

    * `timeout: {:!, pos_integer}` — to not execute update callback after the
      [timeout](AgentMap.html#module-timeout);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

  To swap balances of Alice and Bob:

      update(account, [:Alice, :Bob], fn [a, b] -> [b, a] end)

  #

      iex> %{Alice: 24}
      ...> |> AgentMap.new()
      ...> |> update([:Alice, :Bob], fn [24, nil] -> [1024, 42] end)
      ...> |> get([:Alice, :Bob])
      [1024, 42]

      iex> AgentMap.new()
      ...> |> AgentMap.sleep(:Alice, 20)                                                 # 0
      ...> |> AgentMap.put(:Alice, 3)                                                    # 2
      ...> |> AgentMap.put(:Bob, 0)                                                      # 2
      ...> |> update([:Alice, :Bob], fn [1, 0] -> [2, 2] end, !: {:max, +1}, initial: 1) # 1
      ...> |> update([:Alice, :Bob], fn [3, 2] -> [4, 4] end)                            # 3
      ...> |> get([:Alice, :Bob])
      [4, 4]

      iex> %{a: 42, b: 24}
      ...> |> AgentMap.new()
      ...> |> update([:a, :b], &Enum.reverse/1)
      ...> |> get([:a, :b])
      [24, 42]

      iex> %{a: 42, b: 24}
      ...> |> AgentMap.new()
      ...> |> update([:a, :b], fn _ -> :drop end)
      ...> |> AgentMap.keys()
      []

      iex> %{a: 42, b: 24}
      ...> |> AgentMap.new()
      ...> |> update([:a], fn _ -> :drop end)
      ...> |> AgentMap.update(:b, fn _ -> :drop end)
      ...> |> get([:a, :b])
      [nil, :drop]
  """
  @spec update(am, ([value] -> [value] | :drop | :id), [key], keyword | timeout) :: am
  def update(am, keys, fun, opts \\ []) do
    get_and_update(am, keys, &{am, fun.(&1)}, opts)
  end

  @doc """
  Performs "fire and forget" `update/4` call, using `GenServer.cast/2`.

  Returns *immediately*, without waiting for the actual update occur.

  See `update/4`.

  ## Options

    * `:initial` (`term`, `nil`) — to set initial value for missing keys;

    * `:!` (`priority`, `:avg`) — to set
      [priority](AgentMap.html#module-priority);

    * `timeout: {:!, pos_integer}` — to not execute this call after
      [timeout](AgentMap.html#module-timeout);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> AgentMap.sleep(:a, 20)
      ...> |> cast([:a, :b], fn [2, 2] -> [3, 3] end)                      # 2
      ...> |> cast([:a, :b], fn [1, 1] -> [2, 2] end, !: :max, initial: 1) # 1
      ...> |> cast([:a, :b], fn [3, 3] -> [4, 4] end, !: :min)             # 3
      ...> |> IO.inspect(label: :xi)
      ...> |> get([:a, :b])
      [4, 4]
  """
  @spec cast(am, ([value] -> [value]), [key], keyword) :: am
  @spec cast(am, ([value] -> :drop | :id), [key], keyword) :: am
  def cast(am, keys, fun, opts \\ []) do
    update(am, keys, fun, _prep(opts, !: :avg, cast: true))
  end
end

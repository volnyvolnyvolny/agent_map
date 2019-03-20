defmodule AgentMap.Multi do
  alias AgentMap.Multi

  import AgentMap, only: [is_timeout: 1]

  @moduledoc """
  `AgentMap` supports "multi-key" operations.

  ## Examples

  To swap balances of Alice and Bob:

      iex> %{Alice: 42, Bob: 24}
      ...> |> AgentMap.new()
      ...> |> update([:Alice, :Bob], &Enum.reverse/1)
      ...> |> get([:Alice, :Bob])
      [24, 42]

  To sum them:

      iex> %{Alice: 1, Bob: 999_999}
      ...> |> AgentMap.new()
      ...> |> get([:Alice, :Bob], &Enum.sum/1)
      1_000_000

  Initial value can be provided:

      iex> %{Bob: 999_999}
      ...> |> AgentMap.new()
      ...> |> get([:Bob, :Chris], & &1, default: 0)
      [999_999, 0]

  More complex example:

      iex> am = AgentMap.new(Alice: 10, Bob: 999_990)
      ...>
      iex> get_and_update(am, [:Alice, :Bob], fn [a, b] ->
      ...>   if a >= 10 do
      ...>     a = a - 10
      ...>     b = b + 10
      ...>     [{a, a}, {b, b}]  # [{get, new value}, …]
      ...>   else
      ...>     msg = {:error, "Alice is too poor!"}
      ...>     {msg, [a, b]}     # {get, [new_state, …]}
      ...>   end
      ...> end)
      [0, 1_000_000]

  More on `get_and_update/4` syntax:

      iex> am = AgentMap.new(Alice: 0, Bob: 1_000_000)
      ...>
      iex> get_and_update(am, [:Alice, :Bob], fn _ ->
      ...>   [:pop, :id]
      ...> end)
      [0, 1_000_000]
      iex> get(am, [:Alice, :Bob])
      [nil, 1_000_000]

  ## How it works

  Each multi-key call is handled in a dedicated process. This process is
  responsible for collecting values, invoking callback, updating values,
  returning a result and dealing with possible errors.

  Computation can start only after all the values are known. If it's a
  `get_and_update/4`, `update/4` or a `cast/4` call, to each key involved will
  be sent instruction *"return me a value and wait for a new one"*. This request
  will have a fixed priority `{:avg, +1}`. If it's a `get/4` call with a
  priority ≠ `:now`, to each `key` involved will be sent *"return me a value"*.

  When values are collected, callback can be invoked. If it's a `get/4` call, a
  result of invocation can be returned straight to a caller. Otherwise, updated
  values are sent to a corresponding workers.

  If it's a `get/4` call with an option `!: :now` given, nothing is specially
  collected, callback is invoked immediately, passing current values as an
  argument.

  Most of the time we want to update the same set of keys that were collected.
  The downside is that any activity for each involved key must be blocked until
  all the values are collected and corresponding callback will finish its
  execution. Sometimes it's not a desired behaviour. If so, `call/3` can be
  used:

      iex> am = AgentMap.new(a: 1, b: 2)
      ...>
      iex> Multi.call(am, fn %{a: 1, b: 2} ->
      ...>   {"the sum is 3", %{sum: 1 + 2}}
      ...> end, get: [:a, :b])
      "the sum is 3"
      #
      iex> get(am, [:a, :b, :sum])
      [1, 2, 3]

  — it allows us to update values that were not collected or update only part of
  the collected keys.

      iex> am = AgentMap.new(
      ...>   Alice: 1,
      ...>   Bob: 100,
      ...>   Chris: 1_000_000_000
      ...> )
      ...>
      iex> Multi.call(am, fn accounts ->
      ...>
      ...>   all_money = Enum.sum(Map.values(accounts))
      ...>   accounts = %{Chris: all_money}
      ...>
      ...>   {"now everyone is happy!", accounts}
      ...>
      ...> end, get: :all, upd: :all)
      "now everyone is happy!"
      #
      iex> get(am, [:Alice, :Bob, :Chris])
      [nil, nil, 1_000_000_101]
  """

  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "`AgentMap` server (name, link, pid, …)"
  @type am :: pid | {atom, node} | name | %AgentMap{}

  @type key :: term
  @type value :: term

  ##
  ## PUBLIC PART
  ##

  ##
  ## CALL
  ##

  @doc since: "1.1.2"
  @doc """
  Performs general multi-key call.

  `AgentMap` invokes callback `fun` passing map with **current** values for
  `get` keys (change [priority](AgentMap.html#module-priority) to bypass).

  Callback `fun` takes a `Map` with keys (from `get`) and values, and returns:

    * `{ret, new_map}`, where `ret` is a value to return and `new_map` is a map
      with a new values for keys from `upd`. If some keys are missing in the
      returned map — they are dropped, if some keys are in the map, but not in
      the `upd` — they are created;

    * `{ret, :id}`, where `ret` is a value to return and `upd` values are not
      touched;

    * `{ret, :drop}`, where `ret` is a value to return and all keys from `upd`
      are dropped.

  ## Options

    * `get: [key]`, `[]` — keys that form the `fun` callback argument
      :

          iex> am = AgentMap.new(a: 1, b: 2)
          ...>
          iex> Multi.call(am, fn %{a: 1, b: 2} ->
          ...>   {"the sum is 3", %{sum: 1 + 2}}
          ...> end, get: [:a, :b])
          "the sum is 3"
          #
          iex> get(am, [:a, :b, :sum])
          [1, 2, 3]

    * `upd: [key]`, `[]` — keys that are updated
      :

          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> Multi.call(am, fn %{} ->
          ...>   {":a and :b keys are dropped", %{}}
          ...> end, upd: [:a, :b])
          ":a and :b keys are dropped"
          #
          iex> get(am, [:a, :b, :c], default: :no)
          [:no, :no, 3]

    * `cast: true` — to return immediately;

    * `!: priority`, `:now`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1, b: 2, c: 3)
      ...>
      iex> Multi.call(am, fn m ->
      ...>   {"the sum is \#{Enum.sum(Map.values(m))}"}
      ...> end, get: :all)
      "the sum is 6"
      #
      iex> Multi.call(am, fn %{} ->
      ...>   {:ok, %{a: 6}}
      ...> end, upd: :all)
      :ok
      #
      iex> Multi.call(am, fn m ->
      ...>   {m, :drop}
      ...> end, get: :all, upd: :all)
      %{a: 6}
      #
      iex> get(am, [:a, :b, :c], default: :no)
      [:no, :no, :no]
  """
  @spec call(am, (map -> {ret, map}), keyword | timeout) :: ret when ret: var
  @spec call(am, (map -> {ret, :id}), keyword) :: ret when ret: var
  @spec call(am, (map -> {ret, :drop}), keyword) :: ret when ret: var
  def call(am, fun, opts \\ [get: [], upd: [], !: :now, cast: false, timeout: 5000])

  def call(am, fun, t) when is_timeout(t) do
    call(am, fun, timeout: t)
  end

  def call(am, fun, opts) do
    import Enum, only: [uniq: 1]

    keys = opts[:upd] || []

    unless keys == :all || keys == uniq(keys) do
      raise ArgumentError, """
      expected uniq keys for:

        * `Multi.update/4`, `Multi.get_and_update/4` and `Multi.cast/4` calls;
        * `get: keys`, `upd: keys` arguments of the `Multi.call/3`.

      Got: #{inspect(keys)}
      Check #{inspect(keys -- uniq(keys))}
      """
    end

    req = %Multi.Req{
      get: opts[:get] || [],
      upd: opts[:upd] || [],
      fun: fun,
      timeout: opts[:timeout] || 5000,
      initial: opts[:initial],
      !: opts[:!] || :now
    }

    pid = (is_map(am) && am.pid) || am

    if opts[:cast] do
      GenServer.cast(pid, req)
      am
    else
      GenServer.call(pid, req, req.timeout)
    end
  end

  ##
  ## GET
  ##

  @doc """
  Gets `keys` values via the given `fun`.

  `AgentMap` invokes `fun` passing **current** values for `keys` (change
  [priority](AgentMap.html#module-priority) to bypass).

  ## Options

    * `default: value`, `nil` — value for missing keys;

    * `!: priority`, `:now`;

    * `:timeout`, `5000`.

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 10)                    # 1
      ...> |> put(:a, 2)                       # : ↱ 3
      ...> |> get([:a, :b], & &1, default: 1)  # ↳ 2
      [1, 1]

  But:

      iex> AgentMap.new(a: 1, b: 1)
      ...> |> sleep(:a, 10)                    # 0a
      ...> |> put(:a, 2)                       #  ↳ 1a
      ...> |> get([:a, :b], & &1, !: :avg)     #     ↳ 2ab
      [2, 1]

  this is because of `put/3` by default has a `:max` priority.
  """
  @spec get(am, [key], ([value] -> get), keyword | timeout) :: get when get: var
  def get(am, keys, fun, opts)

  def get(am, keys, fun, t) when is_timeout(t) do
    get(am, keys, fun, timeout: t)
  end

  def get(am, keys, fun, opts) do
    opts =
      opts
      |> Keyword.put_new(:initial, opts[:default])
      |> Keyword.put_new(:get, keys)

    fun = fn map ->
      init = opts[:initial]
      arg = Enum.map(keys, &Map.get(map, &1, init))

      {fun.(arg), :id}
    end

    Multi.call(am, fun, opts)
  end

  #

  @doc """
  Returns values for `keys`.

  Default priority for this call is `:min`.

  ## Options

    * `default: value`, `nil` — value to return if key is missing;

    * `!: priority`, `:min`;

    * `:timeout`, `5000`.

  ## Examples

      iex> AgentMap.new(a: 42)
      ...> |> sleep(:a, 10)     # 1
      ...> |> put(:a, 0)        # ↳ 2
      ...> |> get([:a, :b])     #   ↳ 3
      [0, nil]
  """
  @spec get(am, [key], keyword | timeout) :: [value | nil]
  def get(am, keys, opts \\ [!: :min])

  def get(am, keys, t) when is_timeout(t) do
    get(am, keys, timeout: t)
  end

  def get(am, keys, opts) when is_list(opts) do
    opts = Keyword.put_new(opts, :!, :min)
    get(am, keys, & &1, opts)
  end

  #

  def get(am, keys, fun) do
    get(am, keys, fun, [])
  end

  ##
  ## GET_AND_UPDATE
  ##

  @doc """
  Gets and updates `keys` values.

  `AgentMap` invokes `fun` passing `keys` values. Callback may return:

    * `[{get, new value} | {get} | :id | :pop]`
      :

          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> keys = [:a, :b, :c, :d]
          ...>
          iex> get_and_update(am, keys, fn [1, 2, 3, nil] ->
          ...>   [{:get, :new_value}, {:get}, :pop, :id]
          ...> end)
          [:get, :get, 3, nil]
          #
          iex> get(am, keys)
          [:new_value, 2, nil, nil]

    * `{get, [new value] | :id | :drop}`
      :

          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> keys = [:a, :b, :c, :d]
          ...>
          iex> get_and_update(am, keys, fn [1, 2, 3, nil] ->
          ...>   {:get, [4, 3, 2, 1]}
          ...> end)
          :get
          iex> get(am, keys)
          [4, 3, 2, 1]

    * `{get}`, that is a sugar for `{get, :id}`;

    * `:id`, to return values, while not changing them;

    * `:pop` to return values, while deleting them
      :

          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> keys = [:a, :b, :c, :d]
          ...>
          iex> get_and_update(am, keys, fn _ -> :id end)
          [1, 2, 3, nil]
          iex> get_and_update(am, keys, fn _ -> :pop end)
          [1, 2, 3, nil]
          iex> get(am, keys)
          [nil, nil, nil, nil]

    At the moment only `{:avg, +1}` priority is supported for this call.

  ## Options

    * `initial: value`, `nil` — value for missing keys;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      ...>
      iex> get_and_update(am, [:a, :b], fn [1, 1] ->
      ...>   {:get, [2, 2]}
      ...> end, initial: 1)
      :get
      #
      iex> get_and_update(am, [:a, :b], fn [2, 2] ->
      ...>   {:get, :drop}
      ...> end)
      :get
      iex> get(am, [:a, :b])
      [nil, nil]

  Calls `get_and_update/4`, `update/4` and `cast/4` are **blocking execution**
  for all the keys involved:

      iex> am = AgentMap.new()
      iex> cast(am, [:a, :b], fn _ ->
      ...>   sleep(10); :id
      ...> end)
      ...>
      iex> get(am, [:c], fn _ ->
      ...>   "now"
      ...> end, !: :avg)
      "now"
      iex> get(am, [:c, :b], fn _ ->
      ...>   "10 ms later"
      ...> end, !: :avg)
      "10 ms later"
  """

  @typedoc """
  Callback for `get_and_update/4` call.
  """
  @type cb_m(ret) ::
          ([value] ->
             {ret}
             | {ret, [value] | :drop | :id}
             | [{ret} | {ret, value} | :pop | :id]
             | :pop
             | :id)

  @spec get_and_update(am, [key], cb_m(ret), keyword | timeout) :: ret | [ret | value]
        when ret: var
  def get_and_update(am, keys, fun, opts \\ [])

  def get_and_update(am, keys, fun, t) when is_timeout(t) do
    get_and_update(am, keys, fun, timeout: t)
  end

  def get_and_update(am, keys, fun, opts) do
    opts =
      opts
      |> Keyword.put(:get, keys)
      |> Keyword.put(:upd, keys)

    fun = fn map ->
      init = opts[:initial]
      arg = Enum.map(keys, &Map.get(map, &1, init))

      fun.(arg)
    end

    Multi.call(am, fun, opts)
  end

  ##
  ## UPDATE / CAST
  ##

  @doc """
  Updates `keys` with the given `fun`.

  Callback `fun` may return:

    * `[new value]`;
    * `:id` — to leave values as they are;
    * `:drop` — to drop `keys`.

  At the moment only `{:avg, +1}` priority is supported for this call.

  ## Options

    * `initial: value`, `nil` — value for missing keys;

    * `:timeout`, `5000`.

  ## Examples

      iex> AgentMap.new()
      ...> |> update([:a, :b], fn _ -> [1, 2] end)
      ...> |> update([:a, :b], fn _ -> :id end)
      ...> |> update([:a], fn _ -> :drop end)
      ...> |> get([:a, :b])
      [nil, 2]

      iex> AgentMap.new(a: 6)
      ...> |> sleep(:a, 20)                                          # 0a
      ...> |> put(:a, 1)                                             #  ↳ 1a
      ...>                                                           #     :
      ...> |> update([:a, :b], fn [1, 1] -> [2, 2] end, initial: 1)  #     ↳ 2ab
      ...> |> update([:a, :b], fn [2, 2] -> [3, 3] end)              #         ↳ 3ab
      ...> |> get([:a, :b])                                          #             ↳ 4ab
      [3, 3]
  """
  @spec update(am, [key], ([value] -> [value]), keyword | timeout) :: am
  @spec update(am, [key], ([value] -> :drop | :id), keyword | timeout) :: am
  def update(am, keys, fun, opts \\ []) do
    get_and_update(am, keys, &{am, fun.(&1)}, opts)
  end

  @doc """
  Performs "fire and forget" `update/4` call with `GenServer.cast/2`.

  Returns without waiting for the actual update to finish.

  At the moment only `{:avg, +1}` priority is supported for this call.

  ## Options

    * `initial: value`, `nil` — value for missing keys;

    * `:timeout`, `5000`.

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)
      ...> |> cast([:a, :b], fn [1, 1] -> [2, 2] end, initial: 1)  # 1
      ...> |> cast([:a, :b], fn [2, 2] -> [3, 3] end)              # ↳ 2
      ...> |> get([:a, :b])
      [3, 3]
  """
  @spec cast(am, [key], ([value] -> [value]), keyword | timeout) :: am
  @spec cast(am, [key], ([value] -> :drop | :id), keyword | timeout) :: am
  def cast(am, keys, fun, opts \\ [])

  def cast(am, keys, fun, t) when is_timeout(t) do
    cast(am, keys, fun, timeout: t)
  end

  def cast(am, keys, fun, opts) do
    update(am, keys, fun, [{:cast, true} | opts])
  end
end

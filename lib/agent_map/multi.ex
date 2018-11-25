defmodule AgentMap.Multi do
  alias AgentMap.Multi

  import AgentMap, only: [_call: 3, _prep: 2]
  import Enum, only: [uniq: 1]

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
      ...> |> get([:Bob, :Chris], & &1, initial: 0)
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

  More on `get_and_update` syntax:

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
  returning a result and dealing with a possible errors.

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
  The downside is that any activity for each involved key must be paused until
  all the values are collected and corresponding callback will finish its
  execution. It is not a desired behaviour, for example, if we need only part of
  the values to compute updates, if there is no need in original values at all
  (think of a drop-call) or even if we compute new values using completely
  different set of keys.

  For this particular case `get_and_update/4`, `update/4` and `cast/4` could
  handle keys argument in a form of `{get, upd}`, where `get` is a list of keys
  whose values form the callback argument and `upd` — the keys whose values are
  updated. For example:

      iex> AgentMap.new(a: 1, b: 2, sum: 0)
      ...> |> update({[:a, :b], [:sum]}, fn [1, 2] -> [1 + 2] end)
      ...> |> update({[], [:a, :b]}, fn [] -> :drop end)
      ...> |> get([:a, :b, :sum])
      [nil, nil, 3]
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
  Gets `keys` values via the given `fun`.

  `AgentMap` invokes `fun` passing **current** values for `keys` (change
  [priority](AgentMap.html#module-priority) to bypass).

  ## Options

    * `initial: value`, `nil` — value for missing keys;

    * `!: priority`, `:now`;

    * `:timeout`, `5000`.

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 10)                    # 1 | |
      ...> |> put(:a, 2)                       # | | 3
      ...> |> get([:a, :b], & &1, initial: 1)  # | 2 |
      [1, 1]

      but:

      iex> AgentMap.new(a: 1, b: 1)
      ...> |> sleep(:a, 10)                    # 1 | |
      ...> |> put(:a, 2)                       # | 2 |
      ...> |> get([:a, :b], & &1, !: :avg)     # | | 3
      [2, 1]
  """
  @spec get(am, [key], ([value] -> get), keyword | timeout) :: get when get: var
  def get(am, keys, fun, opts \\ [!: :now]) do
    get_and_update(
      am,
      {keys, []},
      fn keys ->
        {fun.(keys), []}
      end,
      opts
    )
  end

  @doc """
  Returns `keys` values. Sugar for `get(am, keys, & &1, !: :min)`.

  ## Examples

      iex> AgentMap.new(a: 42)
      ...> |> sleep(:a, 10)     # 1 | |
      ...> |> put(:a, 0)        # | 2 |
      ...> |> get([:a, :b])     # | | 3
      [0, nil]
  """
  @spec get(am, [key]) :: [value | nil]
  def get(am, keys), do: get(am, keys, & &1, !: :min)

  @doc """
  Gets and updates `keys` values.

  `AgentMap` invokes `fun` passing `keys` values. Callback may return:

    * `[{get, new value} | {get} | :id | :pop]`
      :

          iex> keys = [:a, :b, :c, :d]
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> get_and_update(am, keys, fn _ ->
          ...>   [{:get, :new_value}, {:get}, :pop, :id]
          ...> end)
          [:get, :get, 3, nil]
          iex> get(am, keys)
          [:new_value, 2, nil, nil]

    * `{get, [new value] | :id | :drop}`
      :

          iex> keys = [:a, :b, :c, :d]
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> get_and_update(am, keys, fn _ ->
          ...>   {:get, [4, 3, 2, 1]}
          ...> end)
          :get
          iex> get(am, keys)
          [4, 3, 2, 1]

    * `{get}`, that is a sugar for `{get, :id}`;

    * `:id`, to return values, while not changing them;

    * `:pop` to return values, while deleting them
      :

          iex> keys = [:a, :b, :c, :d]
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          ...>
          iex> get_and_update(am, keys, fn _ -> :id end)
          [1, 2, 3, nil]
          iex> get_and_update(am, keys, fn _ -> :pop end)
          [1, 2, 3, nil]
          iex> get(am, keys)
          [nil, nil, nil, nil]

  This method can handle `keys` argument in a form of `{get, upd}`, where `get`
  is a list of keys whose values form the `fun` argument and `upd` — the keys
  whose values are planned to update:

      iex> AgentMap.new(a: 1, b: 2)
      ...> |> get_and_update({[:a, :b], []}, fn [1, 2] -> {3, [1 + 2]} end)
      ...> |> update({[], [:a, :b]}, fn [] -> :drop end)
      ...> |> get([:a, :b, :sum])
      [nil, nil, 3]

  ## Options

    * `initial: value`, `nil` — value for missing keys;

    * `!: priority`, `:now` — [priority](AgentMap.html#module-priority) for keys
      that only needs [collecting](#module-how-it-works), for keys that need to
      be updated, `{:avg, +1}` is used.

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
  for all the keys that are collected and updated:

      iex> am = AgentMap.new()
      iex> cast(am, [:a, :b], fn _ -> sleep(10); :id end)
      ...>
      iex> get(am, [:c], fn _ -> "now" end, !: :avg)
      "now"
      iex> get(am, [:c, :b], fn _ -> "10 ms later" end, !: :avg)
      "10 ms later"
  """

  @typedoc """
  Callback for multi-key call.
  """
  @type cb_m(ret) ::
          ([value] ->
             {ret}
             | {ret, [value] | :drop | :id}
             | [{ret} | {ret, value} | :pop | :id]
             | :pop
             | :id)

  @spec get_and_update(am, [key] | {[key], [key]}, cb_m(ret), keyword | timeout) ::
          ret | [ret | value]
        when ret: var
  def get_and_update(am, keys, fun, opts \\ [])

  def get_and_update(am, {get, upd}, fun, opts) do
    unless ks_upd == uniq(ks_upd) do
      raise """
            expected uniq keys for `update`, `get_and_update` and
            `cast` multi-key calls. Got: #{inspect(ks_upd)}. Please
            check #{inspect(ks_upd -- uniq(ks_upd))}.
            """
            |> String.replace("\n", " ")
    end

    opts = _prep(opts, !: :now)
    req = %Multi.Req{get: get, upd: upd, fun: fun, initial: opts[:initial]}

    _call(am, req, opts)
  end

  def get_and_update(am, keys, fun, opts) do
    get_and_update(am, {keys, keys}, fun, opts)
  end

  @doc """
  Updates `keys` with the given `fun`.

  Callback `fun` may return:

    * `[new value]`;
    * `:id` — to leave values as they are;
    * `:drop` — to drop `keys`.

  For this call `{:avg, +1}` priority is used.

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

      iex> AgentMap.new()
      ...> |> sleep(:a, 20)                                                         # 0 | | |
      ...> |> put(:a, 3)                                                            # | | 2 |
      ...> |> put(:b, 0)                                                            # | | 2 |
      ...> |> update([:a, :b], fn [1, 0] -> [2, 2] end, !: {:max, +1}, initial: 1)  # | 1 | |
      ...> |> update([:a, :b], fn [3, 2] -> [4, 4] end)                             # | | | 3
      ...> |> get([:a, :b])
      [4, 4]
  """
  @spec update(am, ([value] -> [value] | :drop | :id), [key], keyword | timeout) :: am
  def update(am, keys, fun, opts \\ []) do
    get_and_update(am, keys, &{am, fun.(&1)}, opts)
  end

  @doc """
  Performs "fire and forget" `update/4` call with `GenServer.cast/2`.

  Returns without waiting for the actual update.

  For this call `{:avg, +1}` priority is used.

  ## Options

    * `initial: value`, `nil` — value for missing keys.

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)
      ...> |> cast([:a, :b], fn [1, 1] -> [2, 2] end, initial: 1)  # 1 |
      ...> |> cast([:a, :b], fn [2, 2] -> [3, 3] end)              # | 2
      ...> |> get([:a, :b])
      [3, 3]
  """
  @spec cast(am, ([value] -> [value]), [key], keyword) :: am
  @spec cast(am, ([value] -> :drop | :id), [key], keyword) :: am
  def cast(am, keys, fun, opts \\ []) do
    update(am, keys, fun, _prep(opts, !: {:avg, +1}, cast: true))
  end
end

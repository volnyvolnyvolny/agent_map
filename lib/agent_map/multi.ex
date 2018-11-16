defmodule AgentMap.Multi do
  alias AgentMap.Multi.Req

  import AgentMap, only: [_call: 3, _prep: 2]

  @moduledoc """
  Functions for making multi-key calls.

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
      ...>     [{a, a}, {b, b}]  # [{get, new value}]
      ...>   else
      ...>     msg = {:error, "Alice is too poor!"}
      ...>     {msg, [a, b]}     # {get, [new_state]}
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
  Gets `keys` values via the given `fun`.

  `AgentMap` invokes `fun` passing `keys` **current** values (change
  [priority](AgentMap.html#module-priority) to bypass).

  ## Options

    * `:initial` (`term`, `nil`) — value for missing keys;

    * `:!` (`priority`, `:now`);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 10)                   # 1
      ...> |> put(:a, 2)                      #   3
      ...> |> get([:a, :b], & &1, initial: 1) #  2
      [1, 1]

      but:

      iex> AgentMap.new(a: 1, b: 1)
      ...> |> sleep(:a, 10)                   # 1
      ...> |> put(:a, 2)                      #  2
      ...> |> get([:a, :b], & &1, !: :avg)    #   3
      [2, 1]
  """
  @spec get(am, [key], ([value] -> get), keyword | timeout) :: get when get: var
  def get(am, keys, fun, opts \\ [!: :now]) do
    opts = _prep(opts, !: :avg)
    req = %Req{act: :get, keys: keys, fun: fun, data: opts[:initial]}

    _call(am, req, opts)
  end

  @doc """
  Returns `keys` values. Sugar for `get(am, keys, & &1, !: :min)`.

  ## Examples

      iex> AgentMap.new(a: 42)
      ...> |> sleep(:a, 10)    # 1
      ...> |> put(:a, 0)       #  2
      ...> |> get([:a, :b])    #   3
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

  ## Options

    * `:initial` (`term`, `nil`) — value for missing keys;

    * `:!` (`priority`, `:avg`);

    * `:timeout` (`timeout`, `5000`).

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

  (!) `get_and_update/4`, `update/4` and `cast/4` calls are blocking execution
  for all `keys`. For ex.:

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

  Callback `fun` may return:

    * `[new values]`;
    * `:id` — to leave values as they are;
    * `:drop` — to drop `keys`.

  ## Options

    * `:initial` (`term`, `nil`) — value for missing keys;

    * `:!` (`priority`, `:avg`);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> AgentMap.new()
      ...> |> update([:a, :b], fn _ -> [1, 2] end)
      ...> |> update([:a, :b], fn _ -> :id end)
      ...> |> update([:a], fn _ -> :drop end)
      ...> |> get([:a, :b])
      [nil, 2]

      iex> AgentMap.new()
      ...> |> sleep(:a, 20)                                                        # 0
      ...> |> put(:a, 3)                                                           #   2
      ...> |> put(:b, 0)                                                           #   2
      ...> |> update([:a, :b], fn [1, 0] -> [2, 2] end, !: {:max, +1}, initial: 1) #  1
      ...> |> update([:a, :b], fn [3, 2] -> [4, 4] end)                            #    3
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

  ## Options

    * `:initial` (`term`, `nil`) — value for missing keys;

    * `:!` (`priority`, `:avg`).

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)
      ...> |> cast([:a, :b], fn [2, 2] -> [3, 3] end)                      #  2
      ...> |> cast([:a, :b], fn [1, 1] -> [2, 2] end, !: :max, initial: 1) # 1
      ...> |> cast([:a, :b], fn [3, 3] -> [4, 4] end, !: :min)             #   3
      ...> |> get([:a, :b])
      [4, 4]
  """
  @spec cast(am, ([value] -> [value]), [key], keyword) :: am
  @spec cast(am, ([value] -> :drop | :id), [key], keyword) :: am
  def cast(am, keys, fun, opts \\ []) do
    update(am, keys, fun, _prep(opts, !: :avg, cast: true))
  end
end

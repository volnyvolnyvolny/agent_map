defmodule AgentMap.Utils do
  alias AgentMap.Req

  import AgentMap.Worker, only: [dict: 1]

  alias AgentMap.Storage

  @wait_time 20
  @max_concurrency 3

  @type am :: AgentMap.am()
  @type key :: AgentMap.key()

  ##
  ## SLEEP
  ##

  @doc """
  Suspends the queue for `key` for `t` ms.

  Returns without waiting for the actual suspend to happen.

  ## Options

    * `cast: false` — to return after the actual sleep;

    * `!: priority`, `{:max, +2}` — to postpone sleep until calls with a higher
      [priority](#module-priority) are executed.
  """
  @spec sleep(am, key, pos_integer | :infinity, keyword) :: am
  def sleep(am, key, t, opts \\ [!: {:max, +2}, cast: true]) do
    opts =
      opts
      |> Keyword.put_new(:!, {:max, +2})
      |> Keyword.put_new(:cast, true)

    AgentMap.get_and_update(
      am,
      key,
      fn _ ->
        :timer.sleep(t)
        :id
      end,
      opts
    )

    am
  end

  ##
  ## META / UPD_META / PUT_META
  ##

  defp default_value(am, key, default) do
    case key do
      :size ->
        length(AgentMap.keys(am))

      :wait_time ->
        @wait_time

      {:wait_time, _key} ->
        @wait_time

      :max_concurrency ->
        @max_concurrency

      {:max_concurrency, _key} ->
        @max_concurrency

      _key ->
        default
    end
  end

  @doc since: "1.1.2"
  @doc """
  Reads metadata information stored under `key`.

  See `put_meta/3`, `upd_meta/3`.

  ## Reserved keys

    * `:size` — current number of keys;

    * `:wait_time` — inactivity period (ms) after which *any* worker should die;

    * `{:wait_time, key}` — inactivity period (ms) after which worker for `key`
      should die;

    * `:max_concurrency` — maximum number of `Task`s each worker can spawn to
      handle `get`-calls;

    * `{:max_concurrency, key}` — maximum number of `Task`s worker can spawn for
      `key`;

    * `:workers` — current number of workers.

  ## Options

    * `default: term`, `nil` — default value if `key` is missing.

  ## Examples

  Basic usage:

      iex> {:ok, am} =
      ...>   AgentMap.start_link([key: 1], meta: [foo: "baz"])
      ...>
      iex> meta(am, :foo)
      "baz"
      iex> meta(am, :key)
      nil
      iex> meta(am, :key, default: 42)
      "foo"
      iex> am
      ...> |> put_meta(:foo, 42)
      ...> |> meta(:foo)
      42

  Monitoring storage usage:

      iex> am = AgentMap.new()
      iex> meta(am, :workers)
      0
      iex> meta(am, :max_concurrency)
      3
      iex> am
      ...> |> sleep(:a, 10)   # creates worker for :a
      ...> |> sleep(:b, 100)  # creates worker for :b
      ...> |> put(:a, 42)
      ...> |> put(:b, 42)
      ...> |> meta(:workers)
      2
      #
      iex> meta(am, :size)
      0
      iex> sleep(50)
      iex> meta(am, :size)
      1
      iex> meta(am, :workers) # worker for :a just died
      1
      #
      iex> sleep(200)
      iex> meta(am, :workers) # worker for :b just died
      0
      iex> meta(am, :size)
      1

  If metadata storage was not created, it will be:

      iex> %_{metadata: nil} = am = AgentMap.new()
      iex> %_{metadata: id} = put_meta(am, :key, 42)
      iex> is_nil?(id)
      false
  """
  @spec meta(am, term, keyword) :: term
  def meta(am, key, opts \\ [default: nil])

  def meta(%_{metadata: m}, key, default: d) when not is_nil(m) do
    Storage.get(m, key, d)
  end

  def meta(%_{server: nil} = am, :workers, _opts) do
    Storage.count_workers(am.storage)
  end

  def meta(%_{server: nil} = am, key, default: d) do
    default_value(am, key, d)
  end

  def meta(%_{server: s} = am, key, default: d) do
    case GenServer.call(s, {:meta, key}) do
      {:ok, value} -> value
      :error -> default_value(am, key, d)
    end
  end

  @doc since: "1.1.2"
  @doc """
  Stores metadata information under `key`.

  Read-only keys: `:size`, `:workers`, `:tasks` (see `meta/2`).

  ## Special keys

    * `wait_time: pos_integer | :infinity`, `20` — number of seconds of
      inactivity after which any worker should die;

    * `{{:wait_time, key}, pos_integer | :infinity}` — number of inactivity ms
      after which worker for `key` should die;

    * `max_concurrency: pos_integer | :infinity`, `3` — a maximum number of
      processes each worker can spawn to handle `get`-calls;

    * `{{:max_concurrency, key}, pos_integer | :infinity}` — maximum number of
      `Task`s worker for `key` can spawn.

  See `meta/2`, `upd_meta/4`.

  ## Options

    * `cast: false` — to wait for the actual put to occur.

  ## Examples

      iex> am = AgentMap.new()
      iex> am
      ...> |> put_meta(:key, 42)
      ...> |> meta(:key)
      42

      iex> am = AgentMap.new()
      iex> meta(am, :bar)
      nil
      iex> meta(am, :bar, :baz)
      :baz
      iex> meta(am, :max_concurrency)
      5000

  Use `meta/2`, `upd_meta/3` and `put_meta/4` functions inside callback:

      iex> am = AgentMap.new()
      iex> am
      ...> |> get(:a, fn _ -> put_meta(am, :foo, :bar) end)
      ...> |> get(:b, fn _ -> meta(am, :foo) end)
      :bar
  """
  @spec put_meta(am, term, term, keyword) :: am
  def put_meta(am, key, value, opts \\ [cast: true])

  def put_meta(am, :max_concurrency, value, opts) do
    put_meta(am, :max_c, value, opts)
  end

  # default values for :max_c or :wait_time
  def put_meta(%_{metadata: nil}, :max_c, :infinity, _opts), do: am
  def put_meta(%_{metadata: nil}, :wait_time, @wait_time, _opts), do: am

  # other values
  def put_meta(am, key, value, opts) do
    upd_meta(am, key, fn _ -> value end, opts)
  end

  #

  @doc since: "1.1.2"
  @doc """
  Updates metadata information stored under `key`.

  See `meta/2`, `put_meta/4`.

  ## Options

    * `cast: false` — to wait for the actual update to occur.

  ## Examples

      iex> AgentMap.new()
      ...> |> put_meta(:key, 42)
      ...> |> upd_meta(:key, fn 42 -> 24 end)
      ...> |> meta(:key)
      24
  """
  @spec upd_meta(am, term, fun, keyword) :: am
  def upd_meta(am, key, fun, opts \\ [cast: true])

  def upd_meta(_am, key, _fun, _opts)
      when key in [
             :processes,
             :size,
             :max_concurrency,
             :max_c
           ] do
    raise """
    Cannot update #{inspect(key)} metadata information stored under key #{inspect(key)}.
    """
  end

  def upd_meta(am, key, fun, opts) do
    req = %Req{act: :upd_meta, key: key, fun: fun}
    AgentMap._call(am, req, opts)
  end

  ##
  ## INC / DEC
  ##

  @doc """
  Increments value with given `key`.

  By default, returns without waiting for the actual increment.

  Raises an `ArithmeticError` if current value associated with key is not a
  number.

  ### Options

    * `step: number`, `1` — increment step;

    * `initial: number`, `0` — initial value;

    * `initial: false` — to raise `KeyError` on server if value does not exist;


    * `cast: false` — to return only after the increment;

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ### Examples

      iex> am = AgentMap.new(a: 1.5)
      iex> am
      ...> |> inc(:a, step: 1.5)
      ...> |> inc(:b, step: 1.5)
      ...> |> get(:a)
      3.0
      iex> get(am, :b)
      1.5

      iex> AgentMap.new()
      ...> |> sleep(:a, 20)
      ...> |> put(:a, 1)               # 1
      ...> |> cast(:a, fn 2 -> 3 end)  # : ↱ 3
      ...> |> inc(:a, !: :max)         # ↳ 2 :
      ...> |> get(:a)                  #     ↳ 4
      3
  """
  @spec inc(am, key, keyword) :: am
  def inc(am, key, opts \\ [step: 1, cast: true, initial: 0, !: :avg]) do
    opts =
      opts
      |> Keyword.put_new(:step, 1)
      |> Keyword.put_new(:initial, 0)
      |> Keyword.put_new(:cast, true)
      |> Keyword.put_new(:!, :avg)

    step =
      opts[:step]
    init = opts[:initial]

    AgentMap.get_and_update(
      am,
      key,
      fn value, exist? ->
        if exist? do
          if is_number(value) do
            {am, value + step}
          else
            k = inspect(key)
            v = inspect(value)

            msg = &"cannot #{&1}rement key #{k} because it has a non-numerical value #{v}"
            msg = msg.((step > 0 && "inc") || "dec")

            raise ArithmeticError, msg
          end
        else
          if init do
            {am, init + step}
          else
            raise KeyError, key: key
          end
        end
      end,
      [{:tiny, true}, {:fun_arity, 2} | opts]
    )
  end

  @doc """
  Decrements value for `key`.

  See `inc/3`.
  """
  @spec dec(am, key, keyword) :: am
  def dec(am, key, opts \\ [step: 1, cast: true, initial: 0, !: :avg]) do
    opts = Keyword.update(opts, :step, -1, &(-&1))
    inc(am, key, opts)
  end
end

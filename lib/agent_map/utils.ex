defmodule AgentMap.Utils do
  alias AgentMap.Req

  import AgentMap.Worker, only: [dict: 1]
  import Task, only: [yield: 2, shutdown: 1]

  @type am :: AgentMap.am()
  @type key :: AgentMap.key()

  @compile {:inline, now: 0}

  defp now(), do: System.monotonic_time(:millisecond)

  ##
  ## SAFE_APPLY
  ##

  @doc since: "1.1.2"
  @deprecated "Just use the `try … rescue / catch` block instead"
  def safe_apply(fun, args) do
    {:ok, apply(fun, args)}
  rescue
    BadFunctionError ->
      {:error, :badfun}

    BadArityError ->
      {:error, :badarity}

    exception ->
      {:error, {exception, __STACKTRACE__}}
  end

  @doc since: "1.1.2"
  @deprecated "Just use `Task.async` → `Task.yield` instead."
  def safe_apply(fun, args, timeout) do
    started_at = now()

    task =
      Task.async(fn ->
        safe_apply(fun, args)
      end)

    case yield(task, timeout - (now() - started_at)) || shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        {:error, :timeout}
    end
  end

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

  @doc since: "1.1.2"
  @doc """
  Reads metadata information stored under `key`.

  Functions `meta/2`, `upd_meta/4` and `put_meta/3` can be used inside
  callbacks.

  ## Special keys

    * `:size` — current size (fast, but in some rare cases inaccurate upwards);

    * `:real_size` — current size (slower, but always accurate);

    * `:max_processes` — a limit for the number of processes allowed to spawn;

    * `:processes` — total number of processes being used (`+1` for server
      itself).

  ## Examples

      iex> am = AgentMap.new()
      iex> meta(am, :processes)
      1
      iex> meta(am, :max_processes)
      5000
      iex> am
      ...> |> sleep(:a, 10)
      ...> |> sleep(:b, 100)
      ...> |> meta(:processes)
      3
      #
      iex> sleep(50)
      iex> meta(am, :processes)
      2
      #
      iex> sleep(200)
      iex> meta(am, :processes)
      1

  #

      iex> am = AgentMap.new()
      iex> meta(am, :size)
      0
      iex> am
      ...> |> sleep(:a, 10)
      ...> |> sleep(:b, 50)
      ...> |> put(:b, 42)
      ...>
      iex> meta(am, :size)       # size calculation is inaccurate, but fast
      2
      iex> meta(am, :real_size)  # that's better
      0
      iex> sleep(50)
      iex> meta(am, :size)       # worker for :a just died
      1
      iex> meta(am, :real_size)
      0
      iex> sleep(40)             # worker for :b just died
      iex> meta(am, :size)
      1
      iex> meta(am, :real_size)
      1

  #

      iex> {:ok, am} =
      ...>   AgentMap.start_link([key: 1], meta: [custom_key: "custom_value"])
      ...>
      iex> meta(am, :custom_key)
      "custom_value"
      iex> meta(am, :unknown_key)
      nil
  """
  @spec meta(am, term) :: term
  def meta(am, key)

  def meta(%{pid: p}, key) do
    meta(p, key)
  end

  def meta(pid, :max_processes) do
    meta(pid, :max_p)
  end

  @forbidden [:size, :real_size, :max_p]

  def meta(pid, k) when k in @forbidden do
    if self() == pid do
      raise """
      Sorry, but meta(am, #{inspect(k)} (or `#{
        @forbidden
        |> List.delete(k)
        |> Enum.join(" and ")
      }`) cannot be called from server process (`tiny: true` was given).
      """
    else
      AgentMap._call(pid, %Req{act: :meta, key: k}, timeout: 5000)
    end
  end

  def meta(pid, key) do
    if self() == pid do
      # we are inside tiny: true :-)
      Process.get(key)
    else
      dict(pid)[key]
    end
  end

  #

  @doc since: "1.1.2"
  @doc """
  Stores metadata information under `key`.

  See `meta/2`, `upd_meta/4`.

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
      iex> meta(am, :max_processes)
      5000

  Functions `meta/2`, `upd_meta/3`, `put_meta/4` can be used inside callbacks:

      iex> am = AgentMap.new()
      iex> am
      ...> |> get(:a, fn _ -> put_meta(am, :foo, :bar) end)
      ...> |> get(:b, fn _ -> meta(am, :foo) end)
      :bar
  """
  @spec put_meta(am, term, term, keyword) :: am
  def put_meta(am, key, value, opts \\ [cast: true]) do
    upd_meta(am, key, fn _ -> value end, opts)
  end

  #

  @doc since: "1.1.2"
  @doc """
  Updates metadata information stored under `key`.

  Underneath, `GenServer.cast/2` is used.

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
      when key in [:processes, :size, :real_size, :max_processes, :max_p] do
    raise """
    Cannot update #{inspect(key)} metadata information stored under key #{inspect(key)}.
    """
  end

  def upd_meta(am, key, fun, opts) do
    req = %Req{act: :upd_meta, key: key, fun: fun}
    AgentMap._call(am, req, opts)
  end

  ##
  ## GET_PROP / SET_PROP / UPD_PROP
  ##

  @doc since: "1.1.2"
  @deprecated "Use `meta/2` instead."
  @spec get_prop(am, term) :: term
  def get_prop(am, key)

  def get_prop(%{pid: p}, key) do
    get_prop(p, key)
  end

  def get_prop(pid, :max_processes) do
    get_prop(pid, :max_p)
  end

  @forbidden [:size, :real_size, :max_p]

  def get_prop(pid, k) when k in @forbidden do
    if self() == pid do
      raise """
      Sorry, but get_prop(am, #{inspect(k)})/2 (the same is for
      `#{@forbidden |> List.delete(k) |> Enum.join(" and ")}`) cannot be called
      from servers process (`tiny: true` was given).
      """
    else
      AgentMap._call(pid, %Req{act: :meta, key: k}, timeout: 5000)
    end
  end

  def get_prop(pid, key) do
    if self() == pid do
      # we are inside tiny: true :-)
      Process.get(key)
    else
      dict(pid)[key]
    end
  end

  @doc "Returns property with given `key` or `default`."
  @deprecated "Use `meta/2` instead"
  def get_prop(am, key, default) do
    req = %Req{act: :meta, key: key, initial: default}
    AgentMap._call(am, req, timeout: 5000)
  end

  #

  @doc since: "1.1.2"
  @deprecated "Use `put_meta/3` instead"
  @spec set_prop(am, term, term) :: am
  def set_prop(am, key, value) do
    upd_prop(am, key, fn _ -> value end)
  end

  #

  @doc since: "1.1.2"
  @deprecated "Use `upd_meta/4` instead"
  @spec upd_prop(am, term, fun) :: am
  def upd_prop(am, key, fun, opts \\ [cast: true])

  def upd_prop(_am, key, _fun, _opts)
      when key in [:processes, :size, :real_size, :max_processes, :max_p] do
    raise "Cannot update #{inspect(key)} prop."
  end

  def upd_prop(am, key, fun, opts) do
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

    step = opts[:step]
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
      [{:tiny, true} | opts]
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

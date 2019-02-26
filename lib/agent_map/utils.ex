defmodule AgentMap.Utils do
  alias AgentMap.Req

  import Task, only: [yield: 2, shutdown: 1]

  @type am :: AgentMap.am()
  @type key :: AgentMap.key()

  @compile {:inline, now: 0}

  defp now(), do: System.monotonic_time(:millisecond)

  ##
  ## SAFE_APPLY
  ##

  @doc """
  Wraps `fun` in a `try…catch` block before applying `args`.

  Returns `{:ok, reply}`, `{:error, reason}`, where `reason` is `:badfun`,
  `:badarity`, `{exception, stacktrace}` or `{:exit, reason}`.

  ## Examples

      iex> safe_apply(:notfun, [])
      {:error, :badfun}

      iex> safe_apply(fn -> 1 end, [:extra_arg])
      {:error, :badarity}

      iex> fun = fn -> exit :reason end
      iex> safe_apply(fun, [])
      {:error, {:exit, :reason}}

      iex> {:error, {e, _stacktrace}} =
      ...>   safe_apply(fn -> raise "oops" end, [])
      iex> e
      %RuntimeError{message: "oops"}

      iex> safe_apply(fn -> 1 end, [])
      {:ok, 1}
  """
  def safe_apply(fun, args) do
    {:ok, apply(fun, args)}
  rescue
    BadFunctionError ->
      {:error, :badfun}

    BadArityError ->
      {:error, :badarity}

    exception ->
      {:error, {exception, __STACKTRACE__}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  @doc """
  Executes `safe_apply(fun, args)` in a separate `Task`. If call takes too long
  — stops its execution.

  Returns `{:ok, reply}`, `{:error, reason}`, where `reason` is `:badfun`,
  `:badarity`, `{exception, stacktrace}`, `{:exit, reason}` or `:timeout`.

  ## Examples

      iex> fun = fn -> sleep(:infinity) end
      iex> safe_apply(fun, [], 20)
      {:error, :timeout}

      iex> fun = fn -> sleep(10); 42 end
      iex> safe_apply(fun, [], 20)
      {:ok, 42}
  """
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
  Sleeps the given `key` for `t` ms.

  Returns without waiting for the actual sleep to happen.

  ## Options

    * `cast: false` — to return after the actual sleep;

    * `!: priority`, `:avg` — to postpone sleep until calls with a higher
      [priority](#module-priority) are executed.
  """
  @spec sleep(am, key, pos_integer | :infinity, keyword) :: am
  def sleep(am, key, t, opts \\ [!: :avg, cast: true]) do
    opts =
      opts
      |> Keyword.put_new(:!, :avg)
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
  ## GET_PROP / PUT_PROP
  ##

  @doc """
  Returns property with given `key` or `default`.

  See `set_prop/3`, `upd_prop/3`.

  ## Special properties

  * `:size` — current size (fast, but in some rare cases inaccurate upwards);

  * `:real_size` — current size (slower, but always accurate);

  * `:max_processes` — a limit for the number of processes allowed to spawn;

  * `:processes` — total number of processes being used (`+1` for server
    itself).

  ## Examples

      iex> am = AgentMap.new()
      iex> get_prop(am, :processes)
      1
      iex> get_prop(am, :max_processes)
      5000
      iex> am
      ...> |> sleep(:a, 10)
      ...> |> sleep(:b, 100)
      ...> |> get_prop(:processes)
      3
      #
      iex> sleep(50)
      iex> get_prop(am, :processes)
      2
      #
      iex> sleep(200)
      iex> get_prop(am, :processes)
      1

  #

      iex> am = AgentMap.new()
      iex> get_prop(am, :size)
      0
      iex> am
      ...> |> sleep(:a, 10)
      ...> |> sleep(:b, 50)
      ...> |> put(:b, 42)
      ...>
      iex> get_prop(am, :size)       # size calculation is inaccurate, but fast
      2
      iex> get_prop(am, :real_size)  # that's better
      0
      iex> sleep(50)
      iex> get_prop(am, :size)       # worker for :a just died
      1
      iex> get_prop(am, :real_size)
      0
      iex> sleep(40)                 # worker for :b just died
      iex> get_prop(am, :size)
      1
      iex> get_prop(am, :real_size)
      1
  """
  @spec get_prop(am, term, term) :: term
  def get_prop(am, key, default \\ nil) do
    req = %Req{act: :get_prop, key: key, initial: default}
    AgentMap._call(am, req, timeout: 5000)
  end

  @doc """
  Stores property in a process dictionary of instance.

  See `get_prop/3`, `upd_prop/4`.

  ## Examples

      iex> am = AgentMap.new()
      iex> am
      ...> |> set_prop(:key, 42)
      ...> |> get_prop(:key)
      42

      iex> am = AgentMap.new()
      iex> get_prop(am, :bar)
      nil
      iex> get_prop(am, :bar, :baz)
      :baz
      iex> get_prop(am, :max_processes)
      5000

  Properties could be used inside callbacks:

      iex> am = AgentMap.new()
      iex> am
      ...> |> get(:a, fn _ -> set_prop(am, :foo, :bar) end)
      ...> |> get(:b, fn _ -> get_prop(am, :foo) end)
      :bar
  """
  @spec set_prop(am, term, term) :: am
  def set_prop(am, key, value) do
    upd_prop(am, key, fn _ -> value end)
  end

  @doc """
  Updates property stored in a process dictionary of instance.

  Underneath, `GenServer.cast/2` is used.

  See `get_prop/3`, `set_prop/3`.

  ## Examples

      iex> AgentMap.new()
      ...> |> set_prop(:key, 42)
      ...> |> upd_prop(:key, fn 42 -> 24 end)
      ...> |> get_prop(:key)
      24
  """
  @spec upd_prop(am, term, fun) :: am
  def upd_prop(am, key, fun)

  def upd_prop(_am, key, _fun)
      when key in [:processes, :size, :real_size, :max_processes, :max_p] do
    throw("Cannot update #{inspect(key)} prop.")
  end

  def upd_prop(am, key, fun) do
    req = %Req{act: :upd_prop, key: key, fun: fun}
    AgentMap._call(am, req, cast: true)
    am
  end

  @doc "Updates property stored in a process dictionary of instance."
  @since "1.1.0"
  @deprecated "Use upd_prop/3 instead"
  @spec upd_prop(am, term, fun, term) :: am
  def upd_prop(am, key, fun, default)

  def upd_prop(_am, key, _fun, _default)
      when key in [:processes, :size, :real_size, :max_processes, :max_p] do
    throw("Cannot update #{inspect(key)} prop.")
  end

  def upd_prop(am, key, fun, default) do
    req = %Req{act: :upd_prop, key: key, fun: fun, initial: default}
    AgentMap._call(am, req, cast: true)
    am
  end

  ##
  ## INC/DEC
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
      ...> |> inc(:b)
      ...> |> get(:a)
      3.0
      iex> get(am, :b)
      1

      iex> AgentMap.new()
      ...> |> sleep(:a, 20)
      ...> |> put(:a, 1)               # 1
      ...> |> cast(:a, fn 2 -> 3 end)  # : ↱ 3
      ...> |> inc(:a, !: :max)         # ↳ 2 :
      ...> |> get(:a)                  #     ↳ 4
      3
  """
  @spec inc(am, key, keyword) :: am
  def inc(am, key, opts \\ [step: 1, initial: 0, !: :avg, cast: true]) do
    opts =
      opts
      |> Keyword.put_new(:step, 1)
      |> Keyword.put_new(:initial, 1)
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

            m = &"cannot #{&1}rement key #{k} because it has a non-numerical value #{v}"
            m = m.((step > 0 && "inc") || "dec")

            raise ArithmeticError, message: m
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

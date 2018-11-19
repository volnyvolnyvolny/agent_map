defmodule AgentMap do
  require Logger

  @enforce_keys [:pid]
  defstruct @enforce_keys

  alias AgentMap.{Req, Multi, Time}

  import Time, only: [now: 0, to_ms: 1]

  @moduledoc """

  `AgentMap` can be seen as a stateful `Map` that parallelize operations made on
  different keys. Basically, it can be used as a cache, memoization,
  computational framework and, sometimes, as a `GenServer` alternative.
  `AgentMap` supports operations made on a group of keys (["multi-key"
  calls](AgentMap.Multi.html)).

  ## Examples

  Create and use it as an ordinary `Map`:

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> AgentMap.get(am, :a)
      42
      iex> AgentMap.keys(am)
      [:a, :b]
      iex> am
      ...> |> AgentMap.update(:a, & &1 + 1)
      ...> |> AgentMap.update(:b, & &1 - 1)
      ...> |> AgentMap.take([:a, :b])
      %{a: 43, b: 23}
      #
      iex> Enum.count(am)
      2

  A special struct `%AgentMap{}` is created via `new/1`. It allows to use the
  `Enumerable` protocol. See also `start/2` and `start_link/2`.

  More complicated example involves memoization:

      defmodule Calc do
        def fib(0), do: 0
        def fib(1), do: 1

        def fib(n) when n >= 0 do
          unless GenServer.whereis(__MODULE__) do
            AgentMap.start_link([], name: __MODULE__)
            fib(n)
          else
            AgentMap.get_and_update(__MODULE__, n, fn
              nil ->
                # This calculation will be made in a separate
                # worker process.
                res = fib(n - 1) + fib(n - 2)
                # Return `res` and set it as a new value.
                {res, res}

              _value ->
                # Change nothing, return current value.
                :id
            end)
          end
        end
      end

  Take a look at the `test/memo.ex`.

  `AgentMap` provides possibility to make "multi-key" calls:

      defmodule Account do
        def start_link() do
          AgentMap.start_link([], name: __MODULE__)
        end

        def stop() do
          AgentMap.stop(__MODULE__)
        end

        @doc \"""
        Returns `{:ok, balance}` or `:error` in case there is no
        such account.
        \"""
        def balance(account) do
          AgentMap.fetch(__MODULE__, account)
        end

        @doc \"""
        Withdraws money. Returns `{:ok, new_amount}` or `:error`.
        \"""
        def withdraw(account, amount) do
          AgentMap.get_and_update(__MODULE__, account, fn
            nil ->     # no such account
              {:error} # (!) refrain from returning `{:error, nil}`
                       # as it would create key with `nil` value

            balance when balance > amount ->
              balance = balance - amount
              {{:ok, balance}, balance}

            _balance ->
              # Returns `:error`, while not changing value.
              {:error}
          end)
        end

        @doc \"""
        Deposits money. Returns `{:ok, new_amount}` or `:error`.
        \"""
        def deposit(account, amount) do
          AgentMap.get_and_update(__MODULE__, account, fn
            nil ->
              {:error}

            balance ->
              balance = balance + amount
              {{:ok, balance}, balance}
          end)
        end

        @doc \"""
        Trasfers money. Returns `:ok` or `:error`.
        \"""
        def transfer(from, to, amount) do
          AgentMap.Multi.get_and_update(__MODULE__, [from, to], fn
            [nil, _] -> {:error}

            [_, nil] -> {:error}

            [b1, b2] when b1 >= amount ->
              {:ok, [b1 - amount, b2 + amount]}

            _ -> {:error}
          end)
        end

        @doc \"""
        Closes account. Returns `:ok` or `:error`.
        \"""
        def close(account) do
          AgentMap.pop(__MODULE__, account) && :ok || :error
        end

        @doc \"""
        Opens account. Returns `:ok` or `:error`.
        \"""
        def open(account) do
          AgentMap.get_and_update(__MODULE__, account, fn
            nil ->
              # Sets balance to 0, while returning :ok.
              {:ok, 0}

            _balance ->
              # Returns :error, while not changing balance.
              {:error}
          end)
        end
      end

  ## Priority (`:!`)

  Most of the functions support `!: priority` option to make out-of-turn
  ("priority") calls.

  Priority can be given as a non-negative integer or alias. Aliases are: `:min |
  :low` = `0`, `:avg | :mid` = `256`, `:max | :high` = `65536`, also, relative
  value can be given, for ex.: `{:max, -1}` = `65535`.

      iex> %{state: :ready}
      ...> |> AgentMap.new()
      ...> |> sleep(:state, 10)
      ...> |> cast(:state, fn :go! -> :stop end)                     # 3
      ...> |> cast(:state, fn :steady -> :go! end, !: :max)          # 2
      ...> |> cast(:state, fn :ready  -> :steady end, !: {:max, +1}) # 1
      ...> |> get(:state)
      :stop

  Also, `!: :now` option can be given in `get/4`, `get_lazy/4` or `take/3` to
  instruct `AgentMap` to make execution in a separate `Task`, using the
  *current* value(s). Calls `fetch!/3`, `fetch/3`, `values/2`, `to_map/2` and
  `has_key?/3` use this by default.

      iex> am =
      ...>   AgentMap.new(state: 1)
      iex> am
      ...> |> sleep(:state, 10)
      ...> |> put(:state, 42)
      ...> |> fetch(:state)
      {:ok, 1}
      iex> get(am, :state, & &1 * 99, !: :now)
      99
      iex> get(am, :state, & &1 * 99)
      4158

  ## Name registration

  `AgentMap` is bound to the same name registration rules as `GenServers`, see
  `GenServer` documentation for details.

  ## Other

  Finally, note that `use AgentMap` defines a `child_spec/1` function, allowing
  the defined module to be put under a supervision tree. The generated
  `child_spec/1` can be customized with the following options:

  * `:id` - the child specification id, defauts to the current module;
  * `:start` - how to start the child process (defaults to calling
    `__MODULE__.start_link/1`);
  * `:restart` - when the child should be restarted, defaults to `:permanent`;
  * `:shutdown` - how to shut down the child.

  For example:

      use AgentMap, restart: :transient, shutdown: 10_000

  See `Supervisor` docs.

  ## How it works

  Underneath it's a `GenServer` that holds a `Map`. When a state changing call
  is first made for a key (`update/4`, `update!/4`, `get_and_update/4`, …), a
  special temporary process called "worker" is spawned. All subsequent calls for
  that key will be forwarded to the message queue of this worker. This process
  respects the order of incoming new calls, executing them in a sequence, except
  for `get/4` calls, which are processed as a parallel `Task`s. For each key,
  the degree of parallelization can be tweaked using `max_processes/3` function.
  The worker will die after about `10` ms of inactivity.
  """

  @max_processes 5

  @typedoc "Return values for `start` and `start_link` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid}} | {:error, [{key}]}

  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "`AgentMap` server (name, link, pid, …)"
  @type am :: pid | {atom, node} | name | %AgentMap{}

  @type key :: term
  @type value :: term
  @type alias :: :low | :mix | :mid | :avg | :high | :max
  @type delta :: integer
  @type priority :: alias | {alias, delta} | :now | non_neg_integer

  @doc false
  def child_spec(funs_and_opts) do
    %{id: AgentMap, start: {AgentMap, :start_link, [funs_and_opts]}}
  end

  @doc false
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @doc false
      def child_spec(funs_and_opts) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [funs_and_opts]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      defoverridable child_spec: 1
    end
  end

  #

  @doc false
  def _call(am, req, opts) do
    req = struct(req, opts)

    if opts[:cast] do
      GenServer.cast(pid(am), req)
      am
    else
      GenServer.call(pid(am), req, opts[:timeout] || 5000)
    end
  end

  @doc false
  def _call(am, req, opts, defs) do
    _call(am, req, _prep(opts, defs))
  end

  #

  defp to_num(:now), do: :now

  defp to_num(p) when p in [:min, :low], do: 0
  defp to_num(p) when p in [:avg, :mid], do: 256
  defp to_num(p) when p in [:max, :high], do: 65536
  defp to_num(i) when is_integer(i) and i >= 0, do: i
  defp to_num({p, delta}), do: to_num(p) + delta

  #

  @doc false
  defp prepair(opts) when is_list(opts), do: opts

  defp prepair(t), do: [timeout: t]

  #

  def _prep(opts, defs) do
    opts =
      opts
      |> prepair()
      |> Keyword.update(:!, to_num(:avg), &to_num/1)

    Keyword.merge(defs, opts)
  end

  ##
  ## PID
  ##

  @doc """
  PID of an `AgentMap` instance.

  ## Examples

      iex> {:ok, pid} = AgentMap.start()
      iex> am = AgentMap.new(pid)
      iex> pid == pid(am)
      true
  """
  def pid(%__MODULE__{pid: p}), do: p
  def pid(p), do: p

  ##
  ## SAFE_APPLY
  ##

  @doc """
  Wraps `fun` in `try…catch` before applying `args`.

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
    past = now()

    task =
      Task.async(fn ->
        safe_apply(fun, args)
      end)

    spent = to_ms(now() - past)

    case Task.yield(task, timeout - spent) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        {:error, :timeout}
    end
  end

  ##
  ## NEW
  ##

  @doc """
  Returns a new instance of `AgentMap`.

  ## Examples

      iex> AgentMap.new()
      ...> |> Enum.empty?()
      true
  """
  @spec new :: am
  def new, do: new(%{})

  @doc """
  Starts an `AgentMap` via `start_link/1` function.

  As an argument, enumerable with keys and values may be provided or the PID of
  an already started `AgentMap`.

  Returns a new instance of `AgentMap` wrapped in a `%AgentMap{}`. This struct
  allows to use `Enumerable` and `Collectable` protocols.

  ## Examples

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> get(am, :a)
      42
      iex> keys(am)
      [:a, :b]

      iex> {:ok, pid}
      ...>   = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.new()
      ...> |> put(:a, 1)
      ...> |> get(:a)
      1

      iex> {:ok, pid}
      ...>   = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.new()
      ...> |> Enum.empty?()
      true

      iex> {:ok, pid}
      ...>   = AgentMap.start_link()
      ...>
      iex> %{a: 2, b: 3}
      ...> |> Enum.into(AgentMap.new(pid))
      ...> |> to_map()
      %{a: 2, b: 3}
  """
  @spec new(Enumerable.t() | am) :: am
  def new(enumerable)

  def new(%__MODULE__{} = am) do
    raise "AgentMap is already started. PID: #{inspect(am.pid)}"
  end

  def new(%_{} = s), do: new(Map.from_struct(s))
  def new(keyword) when is_list(keyword), do: new(Map.new(keyword))

  def new(%{} = m) when is_map(m) do
    funs =
      for {key, value} <- m do
        {key, fn -> value end}
      end

    {:ok, pid} = start_link(funs)
    new(pid)
  end

  def new(p) when is_pid(p), do: %__MODULE__{pid: GenServer.whereis(p)}

  @doc """
  Creates an `AgentMap` instance from `enumerable` via the given transformation
  function.

  Duplicated keys are removed; the latest one prevails.

  ## Examples

      iex> [:a, :b]
      ...> |> AgentMap.new(&{&1, to_string(&1)})
      ...> |> take([:a, :b])
      %{a: "a", b: "b"}
  """
  @spec new(Enumerable.t(), (term -> {key, value})) :: am
  def new(enumerable, transform) do
    new(Map.new(enumerable, transform))
  end

  ##
  ## START / START_LINK
  ##

  @doc """
  Starts a linked `AgentMap` instance.

  Argument `funs` is a keyword that contains pairs `{key, fun/0}`. Each `fun` is
  executed in a separate `Task` and return an initial value for `key`.

  ## Options

    * `:name` (`term`) — is used for registration as described in the module
      documentation;

    * `:debug` — is used to invoke the corresponding function in [`:sys`
      module](http://www.erlang.org/doc/man/sys.html);

    * `:spawn_opt` — is passed as options to the underlying process as in
      `Process.spawn/4`;

    * `:timeout`, `5000` — `AgentMap` is allowed to spend at most
      the given number of milliseconds on the whole process of initialization or
      it will be terminated;

    * `:max_processes` (`pos_integer | :infinity`, `5`) — to seed default
      `:max_processes` value (see `max_processes/2`).

  ## Return values

  If an instance is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a server with the
  specified name already exists, the function returns `{:error,
  {:already_started, pid}}` with the PID of that process.

  If one of the callbacks fails, the function returns `{:error, [{key,
  reason}]}`, where `reason` is `:timeout`, `:badfun`, `:badarity`, `{:exit,
  reason}` or an arbitrary exception.

  ## Examples

      iex> {:ok, pid} =
      ...>   AgentMap.start_link(k: fn -> 42 end)
      iex> get(pid, :k)
      42
      iex> get_prop(pid, :max_processes)
      5

  — starts server with a predefined single key `:k`.

      iex> AgentMap.start(k: 3)
      {:error, k: :badfun}
      iex> AgentMap.start(k: & &1)
      {:error, k: :badarity}
      iex> {:error, k: {e, _st}} =
      ...>   AgentMap.start(k: fn -> raise "oops" end)
      iex> e
      %RuntimeError{message: "oops"}

  #

      iex> AgentMap.start([], name: Account)
      iex> Account
      ...> |> put(:a, 42)
      ...> |> get(:a)
      42
  """
  @spec start_link([{key, (() -> any)}], GenServer.options() | timeout) :: on_start
  def start_link(funs \\ [], opts \\ [max_processes: @max_processes]) do
    opts = prepair(opts)

    args = [
      funs: funs,
      timeout: opts[:timeout] || 5000,
      max_processes: opts[:max_processes] || @max_processes
    ]

    # Global timeout must be turned off.
    opts =
      opts
      |> Keyword.put(:timeout, :infinity)
      |> Keyword.delete(:max_processes)

    GenServer.start_link(AgentMap.Server, args, opts)
  end

  @doc """
  Starts an unlinked `AgentMap` instance.

  See `start_link/2` for details.

  ## Examples

      iex> err =
      ...>   AgentMap.start([a: 42,
      ...>                   b: fn -> sleep(:infinity) end,
      ...>                   c: fn -> raise "oops" end],
      ...>                   timeout: 10)
      ...>
      iex> {:error, a: :badfun, b: :timeout, c: {e, _st}} = err
      iex> e
      %RuntimeError{message: "oops"}
  """
  @spec start([{key, (() -> any)}], GenServer.options() | timeout) :: on_start
  def start(funs \\ [], opts \\ [max_processes: @max_processes]) do
    opts = prepair(opts)

    args = [
      funs: funs,
      timeout: opts[:timeout] || 5000,
      max_processes: opts[:max_processes] || @max_processes
    ]

    # Global timeout must be turned off.
    opts =
      opts
      |> Keyword.put(:timeout, :infinity)
      |> Keyword.delete(:max_processes)

    GenServer.start(AgentMap.Server, args, opts)
  end

  ##
  ## SLEEP
  ##

  @doc """
  Sleeps the given `key` for `t` ms.

  Returns without waiting for the actual sleep to happen and end.

  ## Options

    * `cast: false` — to return after the actual sleep;

    * `!: priority`, `:avg` — to postpone sleep until calls with a lower or
      equal [priorities](#module-priority) are executed.
  """
  @spec sleep(am, key, pos_integer | :infinity, keyword) :: am
  def sleep(am, key, t, opts \\ [!: :avg, cast: true]) do
    req = %Req{act: :sleep, key: key, data: t}
    _call(am, req, opts, !: :avg, cast: true)
    am
  end

  ##
  ## GET / GET_LAZY / FETCH / FETCH!
  ##

  @doc """
  Gets a value via the given `fun`.

  The function `fun` is sent to an instance of `AgentMap` which invokes it,
  passing the value associated with `key`. The result of the invocation is
  returned from this function. This call does not change value, so a series of
  `get`-calls can and will be executed as a parallel `Task`s (see
  `max_processes/3`).

  ## Options

    * `initial: value`, `nil` — value for `key` if it's missing;

    * `!: :now` — to execute call in a separate `Task` (passing a current
      value).

      With this option, any number of `get`-calls could be fired, bypassing the
      instructions given with `:max_processes`:

          iex> am = AgentMap.new()
          iex> for _ <- 1..100 do
          ...>   Task.async(fn ->
          ...>     get(am, :k, fn nil -> sleep(40) end, !: :now)
          ...>   end)
          ...> end
          iex> sleep(10)
          iex> info(am, :k)
          [processes: 100, max_processes: 5]

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new()
      iex> get(am, :Alice, & &1)
      nil
      iex> am
      ...> |> put(:Alice, 42)
      ...> |> get(:Alice, & &1 + 1)
      43
      iex> get(am, :Bob, & &1 + 1, initial: 0)
      1
  """
  @spec get(am, key, (value -> get), keyword | timeout) :: get when get: var
  def get(am, key, fun, opts \\ [!: :avg]) do
    opts = _prep(opts, !: :avg)
    req = %Req{act: :get, key: key, fun: fun, data: opts[:initial]}

    _call(am, req, opts)
  end

  @doc """
  Returns the value for the given `key`.

  Sugar for `get(am, key, & &1, !: :min)`.

  This call is executed with a minimum (`0`) priority. As so, it will start only
  after all other calls awaiting for execution for this `key` are completed.

  See `get/4`.

  ## Examples

      iex> am = AgentMap.new(Alice: 42)
      iex> get(am, :Alice)
      42
      iex> get(am, :Bob)
      nil

      iex> %{Alice: 42}
      ...> |> AgentMap.new()
      ...> |> sleep(:Alice, 10)
      ...> |> put(:Alice, 0)
      ...> |> get(:Alice)
      0
  """
  @spec get(am, key) :: value | nil
  def get(am, key), do: get(am, key, & &1, !: :min)

  @doc """
  Gets the value for a specific `key`.

  If `key` is present, return its value. Otherwise, `fun` is evaluated and its
  result is returned.

  This is useful if the default value is very expensive to calculate or
  generally difficult to setup and teardown again.

  See `get/4`.

  ## Options

    * `!: priority` `:avg` — to return when calls with a lower or equal
      [priorities](#module-priority) are executed;

    * `!: :now` — to execute this call in a separate `Task` (passing a current
      value);

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> fun = fn ->
      ...>   # some expensive operation here
      ...>   13
      ...> end
      iex> get_lazy(am, :a, fun)
      1
      iex> get_lazy(am, :b, fun)
      13
  """
  @spec get_lazy(am, key, (() -> a), keyword | timeout) :: value | a when a: var
  def get_lazy(am, key, fun, opts \\ [!: :avg]) do
    fun = fn value ->
      if Process.get(:value), do: value, else: fun.()
    end

    get(am, key, fun, opts)
  end

  @doc """
  Fetches the value for a specific `key`.

  Returns `{:ok, value}` or `:error` if `key` is not present.

  ## Options

    * `!: priority`, `:now` — to return when calls with a lower or equal
      [priorities](#module-priority) are executed for `key`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> fetch(am, :a)
      {:ok, 1}
      iex> fetch(am, :b)
      :error
      iex> am
      ...> |> sleep(:b, 20)
      ...> |> put(:b, 42)
      ...> |> fetch(:b)
      :error
      iex> am
      ...> |> fetch(:b, !: :min)
      {:ok, 42}
  """
  @spec fetch(am, key, keyword | timeout) :: {:ok, value} | :error
  def fetch(am, key, opts \\ [!: :now]) do
    req = %Req{act: :fetch, key: key}
    _call(am, req, opts, !: :now)
  end

  @doc """
  Fetches the value for a specific `key`, erroring out otherwise.

  Returns current value. Raises a `KeyError` if `key` is not present.

  See `fetch/3`.

  ## Options

    * `!: priority`, `:now` — to return when calls with a lower or equal
      [priorities](#module-priority) are executed for `key`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> fetch!(am, :a)
      1
      iex> fetch!(am, :b)
      ** (KeyError) key :b not found

      iex> AgentMap.new()
      ...> |> sleep(:a, 10)
      ...> |> put(:a, 42)
      ...> |> fetch!(:a, !: :min)
      42
  """
  @spec fetch!(am, key, keyword | timeout) :: value | no_return
  def fetch!(am, key, opts \\ [!: :now]) do
    case fetch(am, key, opts) do
      {:ok, value} ->
        value

      :error ->
        raise KeyError, key: key
    end
  end

  ##
  ## GET_AND_UPDATE
  ##

  @doc """
  Gets the value for `key` and updates it, all in one pass.

  The `fun` is sent to an `AgentMap` that invokes it, passing the value for
  `key`. A `fun` can result in:

    * `{get, new value}` — to return "get" value and set new value;
    * `{get}` — to return "get" value;
    * `:pop` — to return current value and remove `key`;
    * `:id` — to just return current value.

  For example, `get_and_update(account, :Alice, &{&1, &1 + 1_000_000})` returns
  the balance of `:Alice` and makes the deposit, while `get_and_update(account,
  :Alice, &{&1})` just returns the balance.

  This call creates a temporary worker that is responsible for holding queue of
  calls awaiting execution for `key`. If such a worker exists, call is added to
  the end of the queue. Priority can be given (`:!`), to process call out of
  turn.

  See `Map.get_and_update/3`.

  ## Options

    * `initial: value`, `nil` — value for `key` if it's missing;

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 42)
      ...>
      iex> get_and_update(am, :a, &{&1, &1 + 1})
      42
      iex> get(am, :a)
      43
      iex> get_and_update(am, :a, fn _ -> :pop end)
      43
      iex> has_key?(am, :a)
      false
      iex> get_and_update(am, :a, fn _ -> :id end)
      nil
      iex> has_key?(am, :a)
      false
      iex> get_and_update(am, :a, &{&1, &1})
      nil
      iex> has_key?(am, :a)
      true
      iex> get_and_update(am, :b, &{&1, &1}, initial: 42)
      42
      iex> has_key?(am, :b)
      true
  """
  @spec get_and_update(am, key, (value -> {get} | {get, value} | :pop | :id), keyword | timeout) ::
          get | value
        when get: var
  def get_and_update(am, key, fun, opts \\ [!: :avg]) do
    opts = _prep(opts, !: :avg)
    req = %Req{act: :get_and_update, key: key, fun: fun, data: opts[:initial]}

    _call(am, req, opts)
  end

  ##
  ## UPDATE / UPDATE! / REPLACE!
  ##

  @doc """
  Updates `key` with the given `fun`.

  See `get_and_update/4`.

  ## Options

    * `initial: value`, `nil` — value for `key` if it's missing;

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{Alice: 24}
      ...> |> AgentMap.new()
      ...> |> update(:Alice, & &1 + 1_000)
      ...> |> update(:Bob, fn nil -> 42 end)
      ...> |> take([:Alice, :Bob])
      %{Alice: 1024, Bob: 42}

      iex> AgentMap.new()
      ...> |> sleep(:Alice, 20)                                        # 0
      ...> |> put(:Alice, 3)                                           # 2
      ...> |> update(:Alice, fn 1 -> 2 end, !: {:max, +1}, initial: 1) # 1
      ...> |> update(:Alice, fn 3 -> 4 end)                            # 3
      ...> |> values()
      [4]
  """
  @spec update(am, key, (value -> value), keyword | timeout) :: am
  def update(am, key, fun, opts \\ [!: :avg])

  @spec update(am, key, value, (value -> value)) :: am
  def update(am, key, initial, fun) when is_function(fun, 1) do
    update(am, key, initial, fun, 5000)
  end

  def update(am, key, fun, opts) when is_function(fun, 1) do
    get_and_update(am, key, &{am, fun.(&1)}, opts)
  end

  @doc """
  This call exists as a clone of `Map.update/4`.

  See `update/4`.

  ## Options

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Example

      iex> %{a: 42}
      ...> |> AgentMap.new()
      ...> |> update(:a, :initial, & &1 + 1)
      ...> |> update(:b, :initial, & &1 + 1)
      ...> |> take([:a, :b])
      %{a: 43, b: :initial}
  """
  @spec update(am, key, value, (value -> value), keyword | timeout) :: am
  def update(am, key, initial, fun, opts) do
    fun = fn value ->
      if Process.get(:value) do
        fun.(value)
      end || initial
    end

    update(am, key, fun, opts)
  end

  @doc """
  Updates `key` with the given function, but only if `key` already exists.

  If `key` is present, `fun` is invoked with value as argument and its result is
  used as the new value of `key`. If `key` is not present, a `KeyError`
  exception is raised.

  See `update/4`.

  ## Options

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{Alice: 1}
      ...> |> AgentMap.new()
      ...> |> sleep(:Alice, 20)                              # 0
      ...> |> put(:Alice, 3)                                 # 2
      ...> |> update!(:Alice, fn 1 -> 2 end, !: {:max, +1})  # 1
      ...> |> update!(:Alice, fn 3 -> 4 end)                 # 3
      ...> |> update!(:Bob, & &1)
      ** (KeyError) key :Bob not found
  """
  @spec update!(am, key, (value -> value), keyword | timeout) :: am | no_return
  def update!(am, key, fun, opts \\ [!: :avg]) do
    fun = fn value ->
      if Process.get(:value) do
        {:ok, fun.(value)}
      end || {:error}
    end

    case get_and_update(am, key, fun, opts) do
      :error ->
        raise KeyError, key: key

      _ ->
        am
    end
  end

  @doc """
  Alters the value stored under `key`, but only if `key` already exists.

  If `key` is not present, a `KeyError` exception is raised.

  See `update!/4`.

  ## Options

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> am
      ...> |> replace!(:a, 3)
      ...> |> values()
      [3, 2]
      iex> replace!(am, :c, 2)
      ** (KeyError) key :c not found
  """
  @spec replace!(am, key, value, keyword | timeout) :: am
  def replace!(am, key, value, opts \\ [!: :avg]) do
    fun = fn _ -> value end
    update!(am, key, fun, _prep(opts, !: :avg))
  end

  ##
  ## MAX_PROCESSES
  ##

  @doc """
  Sets the `:max_processes` value for `key`.

  `AgentMap` can execute `get/4` calls made on the same key concurrently.
  `max_processes` option specifies number of processes allowed to use per key
  (`+1` for a worker process if it was spawned).

  By default, `5` get-processes per key allowed, but this can be changed via
  `max_processes/2`.

      iex> am = AgentMap.new(k: 42)
      iex> task = fn ->
      ...>   get(am, :k, fn _ -> sleep(10) end)
      ...> end
      iex> for _ <- 1..4, do: spawn(task) # +4
      iex> task.()                        # +1
      :ok

  will be executed in around of `10` ms, not `50`. `AgentMap` can parallelize
  any sequence of `get/3` calls. Sequence ends when a call that change state
  arrive (`get_and_update/3`, `update/3`, etc.)

  Use `max_processes: 1` to execute `get` calls for this `key` sequentially.

  ## Examples

      iex> am = AgentMap.new()
      iex> max_processes(am, :key, 42)
      ...>
      iex> for _ <- 1..1000 do
      ...>   Task.async(fn ->
      ...>     get(am, :key, fn _ -> sleep(10) end)
      ...>   end)
      ...> end
      ...>
      iex> for _ <- 1..250 do
      ...>   sleep(1)                   # every ms
      ...>   info(am, :key)[:processes] # take the amount of processes being used
      ...> end
      ...> |> Enum.max()
      42
      iex> get(am, :key, & &1)
      nil
  """
  @spec max_processes(am, key, pos_integer | :infinity) :: am
  def max_processes(am, key, value)
      when (is_integer(value) and value > 0) or value == :infinity do
    #
    _call(am, %Req{act: :max_processes, key: key, data: value}, timeout: 5000)
    am
  end

  ##
  ## INFO
  ##

  @doc """
  Returns the `:processes` or `:max_processes` numbers for `key`.

  See `info/2`.
  """
  @spec info(am, key, :processes) :: {:processes, pos_integer}
  @spec info(am, key, :max_processes) :: {:max_processes, pos_integer | :infinity}
  def info(am, key, :processes) do
    req = %Req{act: :processes, key: key}
    {:processes, _call(am, req, timeout: 5000)}
  end

  def info(am, key, :max_processes) do
    req = %Req{act: :max_processes, key: key}
    {:max_processes, _call(am, req, timeout: 5000)}
  end

  @doc """
  Returns keyword with the `:processes` and `:max_processes` numbers for `key`.

  ## Examples

      iex> am = AgentMap.new()
      ...>
      iex> info(am, :key)
      [processes: 0, max_processes: 5]
      #
      iex> am
      ...> |> set_prop(:max_processes, 3)
      ...> |> info(:key)
      [processes: 0, max_processes: 3]
      #
      iex> am
      ...> |> sleep(:key, 50)
      ...> |> info(:key)
      [processes: 1, max_processes: 3]

      iex> am = AgentMap.new()
      ...>
      iex> for _ <- 1..10 do
      ...>   Task.async(fn ->
      ...>     get(am, :key, fn _ -> sleep(50) end)
      ...>   end)
      ...> end
      ...>
      iex> sleep(10)
      iex> info(am, :key)[:processes]
      5
      iex> sleep(150)
      iex> info(am, :key)[:processes]
      0

  Keep in mind that:

      iex> am = AgentMap.new()
      iex> for _ <- 1..100 do
      ...>   Task.async(fn ->
      ...>     get(am, :key, fn _ -> sleep(50) end, !: :now)
      ...>   end)
      ...> end
      ...>
      iex> sleep(20)
      ...>
      iex> info(am, :key)[:processes]
      100
  """
  @spec info(am, key) :: [
          processes: pos_integer,
          max_processes: pos_integer | :infinity
        ]
  def info(am, key) do
    [
      info(am, key, :processes),
      info(am, key, :max_processes)
    ]
  end

  ##
  ## GET_PROP / PUT_PROP
  ##

  @doc """
  Returns prop with given `key` or `default` if `key` is not there.

  See `set_prop/3`.
  """
  @spec get_prop(am, term, term) :: term
  def get_prop(am, key, default) do
    req = %Req{act: :get_prop, key: key, data: default}
    _call(am, req, timeout: 5000)
  end

  @doc """
  Returns `:max_processes` or `:processes` (total number) values.

  See `get_prop/3`.

  ## Examples

      iex> am = AgentMap.new()
      iex> get_prop(am, :processes)
      1
      iex> get_prop(am, :max_processes)
      5
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
      iex> get_prop(am, :max_processes)
      5
      iex> am
      ...> |> set_prop(:max_processes, :infinity)
      ...> |> get_prop(:max_processes)
      :infinity
      #
      iex> info(am, :key)[:max_processes]
      :infinity
      #
      iex> max_processes(am, :key, 3)
      iex> info(am, :key)[:max_processes]
      3

  #

      iex> AgentMap.new()
      ...> |> cast(:a, fn nil -> 42 end)
      ...> |> get_prop(:size)
      1
  """
  @spec get_prop(am, :processes) :: pos_integer
  @spec get_prop(am, :max_processes) :: pos_integer | :infinit
  @spec get_prop(am, :size) :: non_neg_integer
  def get_prop(am, key) do
    req = %Req{act: :get_prop, key: key}
    _call(am, req, timeout: 5000)
  end

  @doc """
  Stores key-value pair in a process dictionary of instance.

  The return value of this function is the value that was previously stored
  under `key`, or `nil` in case no value was stored under `key`.

  `AgentMap` depends on `:max_processes` key which defines the default maximum
  amount of processes can be used per key.

  Keys `:processes` and `:size` are reserved — it's impossible to set them.

  See `get_prop/3`.

  ## Examples

      iex> am = AgentMap.new()
      iex> am
      ...> |> set_prop(:key, 42)
      ...> |> get(:b, fn _ -> get_prop(am, :key) end)
      42

      iex> am = AgentMap.new()
      iex> am
      ...> |> get(:a, fn _ -> set_prop(am, :foo, :bar) end)
      ...> |> get(:b, fn _ -> get_prop(am, :foo) end)
      :bar

      iex> am = AgentMap.new()
      iex> get(am, :c, fn _ -> get_prop(am, :bar) end)
      nil
      iex> get(am, :c, fn _ -> get_prop(am, :bar, :baz) end)
      :baz
      iex> get(am, :d, fn _ -> get_prop(am, :max_processes) end)
      5
  """
  @spec set_prop(am, :max_processes, pos_integer) :: am
  @spec set_prop(am, :max_processes, :infinity) :: am
  @spec set_prop(am, term, term) :: am
  def set_prop(_am, key, _value) when key in [:processes, :size] do
    throw("Cannot set values for keys :size and :processes.")
  end

  def set_prop(am, key, value) do
    req = %Req{act: :set_prop, key: key, data: value}
    _call(am, req, cast: true)
    am
  end

  ##
  ## HAS_KEY? / KEYS / VALUES
  ##

  @doc """
  Returns whether the given `key` exists at the moment.

  See `fetch/3`.

  ## Options

    * `!: priority`, `:now`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> has_key?(am, :a)
      true
      iex> has_key?(am, :b)
      false

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)
      ...> |> delete(:a)
      ...> |> has_key?(:a)
      true

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)
      ...> |> delete(:a)
      ...> |> has_key?(:a, !: :min)
      false
  """
  @spec has_key?(am, key, keyword | timeout) :: boolean
  def has_key?(am, key, opts \\ [!: :now]) do
    match?({:ok, _}, fetch(am, key, opts))
  end

  @doc """
  Returns all keys.

  ## Examples

      iex> %{a: 1, b: nil, c: 3}
      ...> |> AgentMap.new()
      ...> |> keys()
      [:a, :b, :c]
  """
  @spec keys(am) :: [key]
  def keys(am), do: _call(am, %Req{act: :keys, !: :now}, timeout: 5000)

  @doc """
  Returns all the current values of an `AgentMap`.

  ## Options

    * `!: priority`, `:now` — to return after calls with a lower or equal
      [priorities](#module-priority) are executed;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> sleep(:a, 20)
      ...> |> put(:a, 0, !: :avg)
      ...> |> values()
      [1, 2, 3]

      iex> %{a: 1, b: 2}
      ...> |> AgentMap.new()
      ...> |> sleep(:a, 20)
      ...> |> put(:a, 0)
      ...> |> values(!: :min)
      [0, 2]
  """
  @spec values(am, keyword | timeout) :: [value]
  def values(am, opts \\ [!: :now]) do
    fun = fn _ ->
      Map.values(Process.get(:map))
    end

    Multi.get(am, keys(am), fun, _prep(opts, !: :now))
  end

  ##
  ## PUT / PUT_NEW / PUT_NEW_LAZY
  ##

  @doc """
  Puts the given `value` under `key`.

  Returns without waiting for the actual put.

  Default [priority](#module-priority) for this call is `:max`.

  ## Options

    * `cast: false` — to return after the actual put;

    * `:!` (`priority`, `:max`);

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> put(:a, 42)
      ...> |> put(:b, 42)
      ...> |> take([:a, :b])
      %{a: 42, b: 42}
  """
  @spec put(am, key, value, keyword) :: am
  def put(am, key, value, opts \\ [!: :max, cast: true]) do
    req = %Req{act: :put, key: key, data: value}
    _call(am, req, opts, !: :max, cast: true)
    am
  end

  @doc """
  Puts the given `value` under `key`, unless the entry already exists.

  Returns without waiting for the actual put.

  Default [priority](#module-priority) for this call is `:max`.

  See `put/4`.

  ## Options

    * `cast: false` — to return after the actual put;

    * `:!` (`priority`, `:max`);

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> put_new(:a, 42)
      ...> |> put_new(:b, 42)
      ...> |> take([:a, :b])
      %{a: 1, b: 42}
  """
  @spec put_new(am, key, value, keyword) :: am
  def put_new(am, key, value, opts \\ [!: :max, cast: true]) do
    req = %Req{act: :put_new, key: key, data: value}
    _call(am, req, opts, !: :max, cast: true)
    am
  end

  @doc """
  Evaluates `fun` and puts the result under `key`, unless it is already present.

  Returns without waiting for the actual put.

  This function is useful in case you want to compute the value to put under
  `key` only if it is not already present (e.g., the value is expensive to
  calculate or generally difficult to setup and teardown again).

  Default [priority](#module-priority) for this call is `:max`.

  See `put_new/4`.

  ## Options

    * `cast: false` — to return after the actual put;

    * `:!` (`priority`, `:max`);

    * `:timeout`, `5000`.

  ## Examples

      iex> fun = fn ->
      ...>   # some expensive operation
      ...>   42
      ...> end
      ...>
      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> put_new_lazy(:a, fun)
      ...> |> put_new_lazy(:b, fun)
      ...> |> take([:a, :b])
      %{a: 1, b: 42}
  """
  @spec put_new_lazy(am, key, (() -> value()), keyword) :: am
  def put_new_lazy(am, key, fun, opts \\ [!: :max, cast: true]) do
    req = %Req{act: :put_new, key: key, fun: fun}
    _call(am, req, opts, !: :max, cast: true)
    am
  end

  ##
  ## POP / DELETE / DROP
  ##

  @doc """
  Removes and returns the value associated with `key`.

  If there is no such `key`, `default` is returned (`nil`).

  ## Options

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am =
      ...>   AgentMap.new(a: 42, b: nil)
      ...>
      iex> pop(am, :a)
      42
      iex> pop(am, :a)
      nil
      iex> pop(am, :a, :error)
      :error
      iex> pop(am, :b, :error)
      nil
      iex> pop(am, :b, :error)
      :error
      iex> Enum.empty?(am)
      true
  """
  @spec pop(am, key, any, keyword | timeout) :: value | any
  def pop(am, key, default \\ nil, opts \\ [!: :avg]) do
    fun = fn _ ->
      if Process.get(:value) do
        :pop
      end || {default}
    end

    get_and_update(am, key, fun, _prep(opts, !: :avg))
  end

  @doc """
  Deletes the entry for `key`.

  Returns without waiting for the actual delete.

  Default [priority](#module-priority) for this call is `:max`.

  ## Options

    * `cast: false` — to return after the actual drop;

    * `!: priority`, `:max`;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1, b: 2}
      ...> |> AgentMap.new()
      ...> |> delete(:a)
      ...> |> take([:a, :b])
      %{b: 2}

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)
      ...> |> delete(:a, !: :min) # 2
      ...> |> put(:a, 2)          # 1
      ...> |> get(:a)             # 3
      nil
  """
  @spec delete(am, key, keyword) :: am
  def delete(am, key, opts \\ [!: :max, cast: true]) do
    req = %Req{act: :delete, key: key}
    _call(am, req, opts, !: :max, cast: true)
    am
  end

  @doc """
  Drops given `keys`.

  Returns without waiting for the actual drop.

  ## Options

    * `cast: false` — to return after the actual drop;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> drop([:b, :d])
      ...> |> take([:a, :b, :c, :d])
      %{a: 1, c: 3}

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> drop([:b, :d], cast: false)
      ...> |> take([:a, :b, :c, :d], !: :now)
      %{a: 1, c: 3}
  """
  @spec drop(am, Enumerable.t(), keyword) :: am
  def drop(am, keys, opts \\ [!: :max, cast: true]) do
    req = %Multi.Req{act: :drop, keys: keys}
    _call(am, req, opts, cast: true)
    am
  end

  ##
  ## TO_MAP / TAKE
  ##

  @doc """
  Returns *immediately* a map representation of an `AgentMap`.

  ## Options

    * `!: priority`, `:now` — to wait until calls with a lower or equal
      priorities are executed;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1, b: 2, c: nil}
      ...> |> AgentMap.new()
      ...> |> sleep(:a, 20)        # 0
      ...> |> put(:a, 42, !: :avg) # 2
      ...> |> to_map()             # 1
      %{a: 1, b: 2, c: nil}

      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> sleep(:a, 20)        # 0
      ...> |> put(:a, 42, !: :avg) # 1
      ...> |> to_map(!: :min)      # 2
      %{a: 42}
  """
  @spec to_map(am, keyword | timeout) :: %{required(key) => value}
  def to_map(am, opts \\ [!: :now]) do
    req = %Req{act: :to_map}
    _call(am, req, opts, !: :now)
  end

  @doc """
  Returns a map with `keys` and values.

  ## Options

    * `!: :now` — to return a snapshot with current keys and values;

    * `:timeout`, `5000`.

  ## Examples

      iex> am =
      ...>   AgentMap.new(a: 1, b: 2, c: 3)
      iex> am
      ...> |> sleep(:a, 20)
      ...> |> put(:a, 42, !: :avg)
      ...> |> sleep(:b, 20)
      ...> |> put(:b, 42, !: :avg)
      ...> |> take([:a, :b, :d], !: :now)
      %{a: 1, b: 2}
      iex> take(am, [:a, :b])
      %{a: 42, b: 42}
  """
  @spec take(am, [key], keyword | timeout) :: map
  def take(am, keys, opts \\ [!: :avg]) do
    fun = fn _ -> Process.get(:map) end

    Multi.get(am, keys, fun, opts)
  end

  ##
  ## INC/DEC
  ##

  @doc """
  Increments value with given `key`.

  By default, returns without waiting for the actual increment.

  ### Options

    * `step: number`, `1` — increment step;

    * `initial: number`, `0` — value if `key` is missing;

    * `initial: false` — to raise `KeyError` on server if value does not exist;


    * `cast: false` — to return after the actual increment;

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
      ...> |> put(:a, 1)              # 1
      ...> |> cast(:a, fn 2 -> 3 end) # 3
      ...> |> inc(:a, !: :max)        # 2
      ...> |> get(:a)
      3
  """
  @spec inc(am, key, keyword) :: am
  def inc(am, key, opts \\ [step: 1, initial: 0, !: :avg, cast: true]) do
    defs = [step: 1, initial: 0, !: :avg, cast: true]
    opts = _prep(opts, defs)
    req = %Req{act: :inc, key: key, data: opts}

    _call(am, req, opts)
    am
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

  ##
  ## CAST
  ##

  @doc """
  Performs "fire and forget" `update/4` call with `GenServer.cast/2`.

  Returns without waiting for the actual update.

  ## Options

    * `!: priority`, `:avg` — to set [priority](#module-priority).

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)
      ...> |> cast(:a, fn 2 -> 3 end)          # 2
      ...> |> cast(:a, fn 1 -> 2 end, !: :max) # 1
      ...> |> cast(:a, fn 3 -> 4 end, !: :min) # 3
      ...> |> get(:a)
      4
  """
  @spec cast(am, key, (value -> value), keyword) :: am
  def cast(am, key, fun, opts \\ [!: :avg]) do
    update(am, key, fun, _prep(opts, !: :avg, cast: true))
  end

  ##
  ## SIZE
  ##

  @doc """
  Returns current size of `AgentMap`.
  """
  # TODO: Remove on 2.0.
  @deprecated "Use `Enum.count/1` or `get_prop(am, :size)` instead."
  @spec size(am) :: non_neg_integer
  def size(am), do: get_prop(am, :size)

  ##
  ## STOP
  ##

  @doc """
  Synchronously stops the `AgentMap` instance with the given `reason`.

  Returns `:ok` if terminated with the given reason. If it terminates with
  another reason, the call will exit.

  This function keeps OTP semantics regarding error reporting. If the reason is
  any other than `:normal`, `:shutdown` or `{:shutdown, _}`, an error report
  will be logged.

  ### Examples

      iex> {:ok, pid} = AgentMap.start_link()
      iex> AgentMap.stop(pid)
      :ok
  """
  @spec stop(am, reason :: term, timeout) :: :ok
  def stop(am, reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop(pid(am), reason, timeout)
  end
end

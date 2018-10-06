defmodule AgentMap do
  @enforce_keys [:pid]
  defstruct @enforce_keys

  alias AgentMap.{Req, IncError, Multi, Worker, CallbackError}

  import Worker, only: [dict: 1]

  @moduledoc """
  `AgentMap` can be seen as a stateful `Map` that parallelize operations made on
  different keys. Basically, it can be used as a cache, memoization,
  computational framework and, sometimes, as a `GenServer` replacement.

  Underneath it's a `GenServer` that holds a `Map`. When an `update/4`,
  `update!/4`, `get_and_update/4` or `cast/4` is first called for a key, a
  special temporary process called "worker" is spawned. All subsequent calls for
  that key will be forwarded to the message queue of this worker. This process
  respects the order of incoming new calls, executing them in a sequence, except
  for `get/4` calls, which are processed as a parallel `Task`s. For each key,
  the degree of parallelization can be tweaked using `max_processes/3` function.
  The worker will die after about `10` ms of inactivity.

  `AgentMap` supports multi-key calls — operations made on a group of keys. See
  `AgentMap.Multi`.

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

  The special struct `%AgentMap{}` can be created via `new/1` function. This
  [allows](#module-enumerable-protocol-and-access-behaviour) to use the
  `Enumerable` protocol.

  Also, `AgentMap` can be started in an `Agent` manner:

      iex> {:ok, pid} = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.put(:a, 1)
      ...> |> AgentMap.get(:a)
      1
      iex> pid
      ...> |> AgentMap.new()
      ...> |> Enum.empty?()
      false

  More complicated example involves memoization:

      defmodule Calc do
        def fib(0), do: 0
        def fib(1), do: 1

        def fib(n) when n >= 0 do
          unless GenServer.whereis(__MODULE__) do
            AgentMap.start_link(name: __MODULE__)
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

  `AgentMap` provides possibility to make multi-key calls (operations on
  multiple keys). Let's see an accounting demo:

      defmodule Account do
        def start_link() do
          AgentMap.start_link(name: __MODULE__)
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

  ## Options

  ### Priority (`:!`)

  Most of the functions support `!: true` option to make out-of-turn
  ("priority") calls.

  By default, on each key, no more than fifth `get/4` calls can be executed
  simultaneously. If `update!/4`, `update/4`, `cast/4`, `get_and_update/4` or a
  `6`-th `get/4` call came, a special worker process will be spawned that became
  the holder of the execution queue. It's the FIFO queue, but priority (`!:
  true`) option can be provided to instruct `AgentMap` to execute a callback in
  the order of preference (out of turn).

  For example:

      iex> import AgentMap
      iex> import :timer
      ...>
      iex> AgentMap.new(state: :ready)
      ...> |> cast(:state, fn :ready  -> sleep(10); :steady end)
      ...> |> cast(:state, fn :go!    -> sleep(10); :stop end)
      ...> |> cast(:state, fn :steady -> sleep(10); :go! end, priority: :max) # ↑
      ...> |> fetch(:state)
      {:ok, :ready}

  — the third one `cast/4` is a priority call, and so takes `:steady` value as
  an argument (not `:stop`).

  ### Snapshot-calls

  Some of the non-changing state functions (`get/4`, `fetch/3`, `fetch!/3`,
  `get_lazy/4`, `take/3`, `values/2`) support `!: true` option to select: return
  immediately or wait for callbacks with lower priority to execute.

  `key` could have an associated queue of callbacks, awaiting of execution. If
  such queue exists, asks a worker to process `fun` in the priority order;

  ### Timeout

  Timeout is an integer greater than zero which specifies how many milliseconds
  are allowed before the `AgentMap` instance executes `fun` and returns a
  result, or an atom `:infinity` to wait indefinitely. If no result is received
  within the specified time, the caller exits. By default it is set to `5000 ms`
  = `5 sec`.

  If no result is received within the specified time, the caller exits, (!) but
  the callback will remain in a queue! To change this behaviour, provide
  `timeout: {:drop, pos_integer}` as a value.

      iex> import AgentMap
      iex> import :timer
      ...>
      iex> Process.flag(:trap_exit, true)
      iex> Process.info(self())[:message_queue_len]
      0
      iex> AgentMap.new(a: 42)
      ...> |> cast(:a, &(sleep(15) && &1))
      ...> |> put(:a, 24, timeout: 10)
      ...> |> put(:a, 33, timeout: {:drop, 10})
      ...> |> fetch(:a, !: false)
      {:ok, 24}
      iex> Process.info(self())[:message_queue_len]
      2

  The second `put/4` was never executed because it was dropped from queue,
  although, `GenServer` exit signal will be send.

  If timeout occurs while callback is executed — it will not be interrupted. For
  this special case `timeout: {:break, pos_integer}` option exist that instructs
  `AgentMap` to wrap call in a `Task`. In the

      cast(am, :key, &(sleep(:infinity) && &1), timeout: {:break, 6000})

  call, callback is wrapped in a `Task` which has `6` sec before *shutdown*.

  ## Name registration

  An `AgentMap` is bound to the same name registration rules as `GenServers`,
  see `GenServer` documentation for details.

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

  See `Supervisor` docs for more information.
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
  def _call(am, req, opts \\ []) do
    req = struct(req, opts)

    case opts[:timeout] do
      {_, t} ->
        GenServer.call(pid(am), req, t)

      t ->
        GenServer.call(pid(am), req, t || 5000)
    end
  end

  #

  @doc """
  Sleeps the given `key` for `t` ms.

  ## Options

    * `:!` (`priority`, `:avg`) to postpone sleep until calls with a lower or
      equal [priorities](#module-priority) are executed.
  """
  @spec sleep(am, key, pos_integer | :infinity, keyword) :: am
  def sleep(am, key, t, opts \\ [!: :avg]) do
    opts = prepair(opts, [!: :avg], forbid: [:break, :drop])
    cast(am, key, fn _ -> :timer.sleep(t) end, opts)
  end

  #

  defp to_num(:now), do: :now

  defp to_num(p) when p in [:min, :low], do: 0
  defp to_num(p) when p in [:avg, :mid], do: 256
  defp to_num(p) when p in [:max, :high], do: 65536
  defp to_num(i) when is_integer(i) and i >= 0, do: i
  defp to_num({p, delta}), do: to_num(p) + delta

  #

  defp prepair(opts, defs, forbid: []) when is_list(opts) do
    t = opts[:timeout]

    if is_integer(t) || t == :infinity do
      raise "Option `timeout: #{inspect(t)}` is not applicable here."
    end

    opts = Keyword.update(opts, :!, to_num(:avg), &to_num/1)

    Keyword.merge(defs, opts)
  end

  defp prepair(t, defs, forbid: []) do
    prepair([timeout: t], defs, forbid: [])
  end

  defp prepair(opts, defs, forbid: forbid) do
    for what <- forbid do
      if match?({^what, _}, opts[:timeout]) do
        raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable
        here."
      end
    end

    prepair(opts, defs, forbid: [])
  end

  ## HELPERS ##

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

  @doc """
  Wraps `fun` in `try…catch` before applying `args`.

  Returns `{:ok, reply}`, `{:error, :badfun | :badarity}` or `{:error,
  {exception, stacktrace} | {:exit, reason}}`.

  ## Examples

      iex> import AgentMap
      ...>
      iex> safe_apply(:notfun, [])
      {:error, :badfun}
      iex> safe_apply(fn -> 1 end, [:extra_arg])
      {:error, :badarity}
      iex> safe_apply(fn -> 1 end, [])
      {:ok, 1}
      #
      iex> {:error, {e, _stacktrace}} =
      ...>   safe_apply(fn -> raise "oops" end, [])
      iex> e
      %RuntimeError{message: "oops"}
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

  ## ##

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

  Returns a new instance of `AgentMap` wrapped in a `%AgentMap{}`.

  As an argument, enumerable with keys and values may be provided or the PID of
  an already started `AgentMap`.

  ## Examples

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> AgentMap.get(am, :a)
      42
      iex> AgentMap.keys(am)
      [:a, :b]

      iex> {:ok, pid} = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.new()
      ...> |> AgentMap.put(:a, 1)
      ...> |> AgentMap.fetch(:a, !: false)
      {:ok, 1}
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
      ...> |> AgentMap.take([:a, :b])
      %{a: "a", b: "b"}
  """
  @spec new(Enumerable.t(), (term -> {key, value})) :: am
  def new(enumerable, transform) do
    new(Map.new(enumerable, transform))
  end

  #

  defp prepair(funs, opts) when is_list(opts) do
    args = [
      funs: funs,
      timeout: opts[:timeout] || :infinity,
      max_processes: opts[:max_processes] || @max_processes
    ]

    # Global timeout must be turned off.
    gen_server_opts =
      opts
      |> Keyword.put(:timeout, :infinity)
      |> Keyword.delete(:max_processes)

    {args, gen_server_opts}
  end

  defp prepair(funs, timeout: t), do: prepair(funs, timeout: t)

  @doc """
  Starts an `AgentMap` instance linked to the current process.

  The `funs` keyword must contain pairs `{key, fun/0}`. Each `fun` is executed
  in a separate `Task` and return an initial value for `key`.

  ## Options

    * `:name` (any) — is used for registration as described in the module
      documentation;

    * `:debug` — is used to invoke the corresponding function in [`:sys`
      module](http://www.erlang.org/doc/man/sys.html);

    * `:spawn_opt` — is passed as options to the underlying process as in
      `Process.spawn/4`;

    * `:timeout` (`pos_integer | :infinity`, `:infinity`) — `AgentMap` is
      allowed to spend at most the given number of milliseconds on the whole
      process of initialization or it will be terminated;

    * `:max_processes` (`pos_integer | :infinity`, `5`) — to seed default
      `:max_processes` value (see `max_processes/2`).

  ## Return values

  If the server is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a server with the
  specified name already exists, the function returns `{:error,
  {:already_started, pid}}` with the PID of that process.

  If one of the callbacks fails, the function returns `{:error, [{key,
  reason}]}`, where `reason` is `:timeout`, `:badfun`, `:badarity`, `{:exit,
  reason}` or an arbitrary exception.

  ## Examples

      iex> {:ok, pid} =
      ...>   AgentMap.start_link(k: fn -> 42 end)
      iex> AgentMap.get(pid, :k)
      42
      iex> max_processes(pid)
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
  """
  @spec start_link([{key, (() -> any)}], GenServer.options() | timeout) :: on_start
  def start_link(funs \\ [], opts \\ [max_processes: 5]) do
    {args, opts} = prepair(funs, opts)
    GenServer.start_link(AgentMap.Server, args, opts)
  end

  @doc """
  Starts an `AgentMap` instance as an unlinked process.

  See `start_link/2` for details.

  ## Examples

      iex> import :timer
      ...>
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
  def start(funs \\ [], opts \\ [max_processes: 5]) do
    {args, opts} = prepair(funs, opts)
    GenServer.start(AgentMap.Server, args, opts)
  end

  ##
  ## GET
  ##

  @doc """
  Gets a value via the given `fun`.

  The function `fun` is sent to an instance of `AgentMap` which invokes it,
  passing the value associated with `key` (or `nil`). The result of the
  invocation is returned from this function. This call does not change value, so
  a series of `get`-calls can and will be executed as a parallel `Task`s (see
  `max_processes/3`).

  ## Options

    * `:initial` (`term`, `nil`) — if value does not exist it is considered to
      be the one given as initial;

    * `:!` (`priority`, :avg) — to wait until calls with a lower or equal
      [priorities](#module-priority) are executed;

    * `!: :now` — to make this call in a separate `Task`, providing the current
      value as an argument.

      This calls are not counted in a number of processes allowed to run in
      parallel (see `max_processes/3`):

          iex> import AgentMap
          iex> import :timer
          ...>
          iex> am = AgentMap.new()
          iex> info(am, :k)[:max_processes]
          5
          #
          iex> fun =
          ...>   fn nil -> sleep(40); &1 end
          ...>
          iex> for _ <- 1..100 do
          ...>   Task.async(fn ->
          ...>     get(am, :k, fun, !: :now)
          ...>   end)
          ...> end
          iex> sleep(10)
          iex> info(am, :k)[:processes]
          100

    * `timeout: {:drop, pos_integer}` — to drop `fun` from queue upon the
      occurence of [timeout](#module-timeout);

    * `timeout: {:break, pos_integer}` — to drop `fun` from queue or break a
      running `fun` upon the occurence of [timeout](#module-timeout);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> import AgentMap
      ...>
      iex> am = AgentMap.new()
      iex> get(am, :Alice, & &1)
      nil
      iex> am
      ...> |> put(:Alice, 42)
      ...> |> get(:Alice, & &1 + 1)
      43
      iex> am
      ...> |> get(:Bob, & &1 + 1, initial: 0)
      1
  """
  @spec get(am, key, (value -> get), keyword | timeout) :: get when get: var
  def get(am, key, fun, opts \\ [!: :avg]) do
    req = %Req{action: :get, key: key, fun: fun, data: opts[:initial]}
    _call(am, struct(req, opts))
  end

  @doc """
  Returns the value for the given `key`.

  The execution of this call is started only when all the other calls for this
  `key` are completed.

  Syntactic sugar for

      get(am, key, & &1, !: :min)

  See `get/4`.

  ## Examples

      iex> am = AgentMap.new(Alice: 42)
      iex> AgentMap.get(am, :Alice)
      42
      iex> AgentMap.get(am, :Bob)
      nil

      iex> %{Alice: 42}
      ...> |> AgentMap.new()
      ...> |> AgentMap.sleep(:Alice, 10)
      ...> |> AgentMap.put(:Alice, 0)
      ...> |> AgentMap.get(:Alice)
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

  ## Options

    * `:!` (`priority`, :avg) — to wait until calls with a lower or equal
      [priorities](#module-priority) are executed;

    * `timeout: {:drop, pos_integer}` — to drop `fun` from queue upon the
      occurence of [timeout](#module-timeout);

    * `timeout: {:break, pos_integer}` — to drop `fun` from queue or break a
      running `fun` upon the occurence of [timeout](#module-timeout);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> fun = fn ->
      ...>   # some expensive operation here
      ...>   13
      ...> end
      iex> AgentMap.get_lazy(am, :a, fun)
      1
      iex> AgentMap.get_lazy(am, :b, fun)
      13
  """
  @spec get_lazy(am, key, (() -> a), keyword | timeout) :: value | a when a: var
  def get_lazy(am, key, fun, opts \\ []) do
    fun = fn value ->
      if Process.get(:value) do
        value
      else
        fun.()
      end
    end

    get(am, key, fun, opts)
  end

  ##
  ## GET_AND_UPDATE
  ##

  @doc """
  Gets the value for `key` and updates it, all in one pass.

  The function `fun` is sent to an `AgentMap` instance that invokes it, passing
  the value associated with `key` (or `nil`). The result of an invocation is
  returned from this function.

  A `fun` can return:

    * a two element tuple: `{"get" value, new value}`;
    * a one element tuple `{"get" value}` — the value is not changed;
    * `:pop` — similar to `Map.get_and_update/3` this returns value with given
      `key` and removes it;
    * `:id` to return a current value, while not changing it.

  For example, `get_and_update(account, :Alice, & {&1, &1 + 1_000_000})` returns
  the balance of `:Alice` and makes the deposit, while `get_and_update(account,
  :Alice, & {&1})` just returns the balance.

  This call creates a temporary worker that is responsible for holding queue of
  calls awaiting execution for `key`. If such a worker exists, call is added to
  the end of the queue. Priority can be given (`:!`), to process call out of
  turn.

  ## Options

    * `:initial` — (`term`, `nil`) if value does not exist it is considered to
      be the one given as initial;

    * `:!` (`priority`, `:avg`) — to put this call in a queue with given
      [priority](#module-priority);

    * `timeout: {:drop, pos_integer}` — to drop this call from queue after given
      number of milliseconds;

    * `timeout: {:break, pos_integer}` — to drop this call from queue or break a
      running one upon the occurence of [timeout](#module-timeout);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> import AgentMap
      ...>
      iex> am = AgentMap.new(a: 42)
      ...>
      iex> get_and_update(am, :a, & {&1, &1 + 1})
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
      iex> get_and_update(am, :a, & {&1, &1})
      nil
      iex> has_key?(am, :a)
      true
      iex> get_and_update(am, :b, & {&1, &1}, initial: 42)
      42
      iex> has_key?(am, :b)
      true
  """
  @spec get_and_update(am, key, (value -> {get} | {get, value} | :pop | :id), keyword | timeout) ::
          get | value
        when get: var
  def get_and_update(am, key, fun, opts \\ [!: :avg]) do
    defs = [!: :avg]
    opts = prepair(opts, defs, forbid: [:break])

    req = %Req{action: :get_and_update, key: key, fun: fun, data: opts[:initial]}

    _call(am, struct(req, opts))
  end

  @doc """
  Gets the value from `key` and updates it. Raises if there is no `key`.

  Behaves exactly like `get_and_update/4`, but raises a `KeyError` exception if
  `key` is not present.

  See `get_and_update/4`.

  ## Options

  All the same as for [`get_and_update/4`](#get_and_update/4-options), except
  for `:initial`.

  ## Examples

      iex> import AgentMap
      iex> #
      ...> am = AgentMap.new(a: 1)
      iex> #
      ...> get_and_update!(am, :a, fn value ->
      ...>   {value, "new value!"}
      ...> end)
      1
      iex> get_and_update!(am, :a, fn _ -> :pop end)
      "new value!
      iex> has_key?(am, :a)
      nil
      iex> get_and_update!(am, :b, fn _value -> :id end)
      ** (KeyError) key :b not found
  """
  @spec get_and_update!(am, key, (value -> {get} | {get, value} | :pop | :id), keyword | timeout) ::
          get | value | no_return
        when get: term
  def get_and_update!(am, key, fun, opts \\ []) do
    fun = fn [value] ->
      map = Process.get(:map)

      if Map.has_key?(map, key) do
        case fun.(value) do
          {get} ->
            get = {:ok, get}
            [{get}]

          {get, v} ->
            [{{:ok, get}, v}]

          :id ->
            get = {:ok, value}
            [{get}]

          :pop ->
            {{:ok, value}, :drop}

          reply ->
            raise CallbackError, got: reply
        end
      end || {:error}
    end

    case Multi.get_and_update(am, [key], fun, opts) do
      {:ok, get} ->
        get

      :error ->
        raise KeyError, key: key
    end
  end

  ##
  ## UPDATE
  ##

  @doc """
  Updates `key` with the given `fun`.

  Syntactic sugar for

      get_and_update(am, key, &{am, fun.(&1)}, opts)

  See `get_and_update/4`.

  This call creates a temporary worker that is responsible for holding queue of
  calls awaiting execution for `key`. If such a worker exists, call is added to
  the end of the queue. Priority can be given (`:!`), to process call out of
  turn.

  ## Options

  The same as for [`get_and_update/4`](#get_and_update/4-options) call.

  ## Examples

      iex> import AgentMap
      iex> #
      ...> %{Alice: 24}
      ...> |> AgentMap.new()
      ...> |> update(:Alice, & &1 + 1_000)
      ...> |> update(:Bob, fn nil -> 42 end)
      ...> |> take([:Alice, :Bob])
      %{Alice: 1024, Bob: 42}
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

  The same as for [`get_and_update/4`](#get_and_update/4-options) call.

  ## Example

      iex> import AgentMap
      iex> #
      ...> %{a: 42}
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
  Updates `key` with the given function.

  If `key` is present, `fun` is invoked with value as argument and its result is
  used as the new value of `key`. If `key` is not present, a `KeyError`
  exception is raised.

  See `update/4`.

  ## Options

  All the same as for [`get_and_update/4`](#get_and_update/4-options) call,
  except for `:initial`.

  ## Examples

      iex> import AgentMap
      ...>
      iex> am = AgentMap.new(Alice: 1)
      iex> am
      ...> |> sleep(:Alice, 20)
      ...> |> put(:Alice, 2)
      ...> |> cast(:Alice, fn 3 -> 4 end)
      ...> |> update!(:Alice, fn 4 -> 5 end)
      ...> |> update!(:Alice, fn 2 -> 3 end, !: true)
      ...> |> fetch(:Alice, !: false)
      {:ok, 5}
      #
      iex> update!(am, :Bob, & &1)
      ** (KeyError) key :Bob not found
  """
  @spec update!(am, key, (value -> value), keyword | timeout) :: am | no_return
  def update!(am, key, fun, opts \\ [!: :avg]) do
    fun = fn value ->
      if Process.get(:value) do
        {:ok, fun.(value)}
      end || {:error}
    end

    res = get_and_update(am, key, fun, opts)

    if :ok == res do
      am
    else
      raise KeyError, key: key
    end
  end

  @doc """
  Alters the value stored under `key`, but only if `key` already exists.

  If `key` is not present, a `KeyError` exception is raised.

  Syntactic sugar for

      update!(am, key, fn _ -> value end, opts)

  See `update!/4`.

  ## Options

    * `:!` (`priority`, `:avg`) — to put this call in a queue with given
      [priority](#module-priority). If worker (queue holder) was not spawned for
      `key`, the value is replaced *immediately*;

    * `timeout: {:drop, pos_integer}` — to cancel replacement upon the occurence
      of a [timeout](#module-timeout);

    * `:timeout` (`pos_integer | :infinity`, `5000`).

  ## Examples

      iex> import AgentMap
      ...>
      iex> am = AgentMap.new(a: 1, b: 2)
      iex> am
      ...> |> replace!(:a, 3)
      ...> |> values()
      [3, 2]
      iex> am
      ...> |> replace!(:c, 2)
      ** (KeyError) key :c not found
  """
  @spec replace!(am, key, value, keyword | timeout) :: am
  def replace!(am, key, value, opts \\ [!: :avg]) do
    opts = prepair(opts, [!: :avg], forbid: [:break])
    update!(am, key, fn _ -> value end, opts)
  end

  ##
  ## CAST
  ##

  @doc """
  Performs `cast` ("fire and forget"). Works the same as `update/4`, but uses
  `GenServer.cast/2` internally.

  Returns *immediately*, without waiting for the actual update to occur.

  This call creates a temporary worker that is responsible for holding queue of
  calls awaiting execution for `key`. If such a worker exists, call is added to
  the end of the queue. Priority can be given (`:!`), to process call out of
  turn.

  ## Options

    * `:!` (`priority`, `:avg`) — to put this call in a queue with given
      [priority](#module-priority). If worker (queue holder) was not spawned for
      `key`, the value is fetched *immediately*;

    * `timeout: {:drop, pos_integer}` — to drop call from queue upon the
      occurence of [timeout](#module-timeout);

    * `timeout: {:break, pos_integer}` — to drop call from queue or cancel `fun`
      that is runnig upon the occurence of [timeout](#module-timeout).

  Caller will not receive exit signal when timeout occurs.

  ## Examples

      iex> import AgentMap
      iex> import :timer
      ...>
      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> cast(:a, fn 1 -> sleep(20); 2 end) # 0
      ...> |> cast(:a, fn 3 -> 4 end)            # 2
      ...> |> cast(:a, fn 2 -> 3 end, !: :max)   # 1
      ...> |> cast(:a, fn 3 -> 4 end, !: :min)   # 3
      ...> |> get(:a)
      1
  """
  @spec cast(am, key, (value -> value), keyword) :: am
  def cast(am, key, fun, opts \\ [!: :avg]) do
    req = %Req{action: :get_and_update, key: key, fun: &{:_get, fun.(&1)}}
    opts = prepair(opts, [cast: true, !: :avg], forbid: [])

    GenServer.cast(pid(am), struct(req, opts))
    am
  end

  @doc """
  Returns the default `:max_processes` value.

  See `max_processes/3`.

  ## Examples

      iex> import AgentMap
      ...>
      iex> am = AgentMap.new()
      iex> max_processes(am)
      5
      iex> max_processes(am, :infinity)
      ...>
      iex> :timer.sleep(10)
      ...>
      iex> max_processes(am)
      :infinity
      #
      iex> info(am, :key)[:max_processes]
      :infinity
      #
      iex> max_processes(am, :key, 3)
      iex> info(am, :key)[:max_processes]
      3
  """
  @spec max_processes(am) :: pos_integer | :infinity
  def max_processes(am) do
    dict(pid(am))[:max_processes]
  end

  @doc """
  Sets the default `:max_processes` value.

  See `max_processes/3`.

  ## Examples

      iex> import AgentMap
      ...>
      iex> am = AgentMap.new()
      iex> max_processes(am)
      5
      iex> max_processes(am, :infinity)
      ...>
      iex> :timer.sleep(10)
      ...>
      iex> max_processes(am)
      :infinity
  """
  @spec max_processes(am, pos_integer | :infinity) :: am
  def max_processes(am, value)
      when (is_integer(value) and value > 0) or value == :infinity do
    GenServer.cast(pid(am), %Req{action: :max_processes, data: value})
    am
  end

  @doc """
  Sets the `:max_processes` value for `key`.

  `AgentMap` can execute `get/4` calls made on the same key concurrently.
  `max_processes` option specifies number of processes allowed to use per key
  (`-1` if a worker process was spawned).

  By default, `5` get-processes per key allowed, but this can be changed via
  `max_processes/2`.

      iex> import AgentMap
      iex> import :timer
      ...>
      iex> am = AgentMap.new(k: 42)
      iex> task = fn ->
      ...>   get(am, :k, fn _ -> sleep(10) end)
      ...> end
      iex> for _ <- 1..4, do: spawn(task) #+4
      iex> task.()                        #+1
      :ok

  will be executed in around of `10` ms, not `50`. `AgentMap` can parallelize
  any sequence of `get/3` calls ending with `get_and_update/3`, `update/3` or
  `cast/3`.

  Use `max_processes: 1` to execute `get` calls in a sequence.

  ## Examples

      iex> import AgentMap
      ...>
      iex> am = AgentMap.new()
      iex> max_processes(am, :key, 42)
      ...>
      iex> for _ <- 1..1000 do
      ...>   Task.async(fn ->
      ...>     get(am, :key, fn _ -> sleep(10) end)
      ...>   end)
      ...> end
      ...>
      iex> for _ <- 1..50 do
      ...>   sleep(2) # — every 2 ms in 100 ms.
      ...>   info(am, :key)[:max_processes]
      ...> end
      ...> |> Enum.max()
      42
      iex> fetch(am, :key, !: false)
      :error
  """
  @spec max_processes(am, key, pos_integer | :infinity) :: am
  def max_processes(am, key, value)
      when (is_integer(value) and value > 0) or value == :infinity do
    req = %Req{action: :max_processes, key: {key}, data: value}

    GenServer.cast(pid(am), req)
    am
  end

  @doc """
  Returns information about `key` — number of processes or maximum processes
  allowed.

  See `info/2`.
  """
  @spec info(am, key, :processes) :: {:processes, pos_integer}
  @spec info(am, key, :max_processes) :: {:max_processes, pos_integer | :infinity}
  def info(am, key, :processes) do
    p = _call(am, %Req{action: :processes, key: key})
    {:processes, p}
  end

  def info(am, key, :max_processes) do
    max_p = _call(am, %Req{action: :max_processes, key: {key}})
    {:max_processes, max_p}
  end

  @doc """
  Returns keyword with number of processes and maximum number of processes
  allowed for key.

  ## Examples

      iex> import AgentMap
      ...>
      iex> am = AgentMap.new()
      ...>
      iex> info(am, :key)
      [processes: 0, max_processes: 5]
      #
      iex> am
      ...> |> max_processes(3)
      ...> |> info(:key)
      [processes: 0, max_processes: 3]
      #
      iex> am
      ...> |> sleep(:key, 10)
      ...> |> info(:key)
      [processes: 1, max_processes: 3]
      #
      iex> am
      ...> |> max_processes(5)
      ...> |> info(:key)
      [processes: 1, max_processes: 5]
      #
      iex> for _ <- 1..100 do
      ...>   Task.async(fn ->
      ...>     get(am, :key, fn _ -> sleep(5) end)
      ...>   end)
      ...> end
      iex> sleep(5)
      iex> info(am, :key)[:processes]
      5
      iex> sleep(50)
      iex> info(am, :key)[:processes]
      1

  But keep in mind, that:

      iex> import AgentMap
      iex> import :timer
      ...>
      iex> am = AgentMap.new()
      iex> for _ <- 1..100 do
      ...>   Task.async(fn ->
      ...>     get(am, :key, fn _ -> sleep(50) end, !: true)
      ...>   end)
      ...> end
      ...>
      iex> sleep(10)
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

  @doc """
  Fetches the value for a specific `key`.

  If the value for a given `key` exists, `{:ok, value}` is returned. If it
  doesn’t contain `key`, `:error` is returned. Returns value *immediately*,
  unless `!: priority` is provided.

  ## Options

    * `:!` (`priority`) — to wait until calls with a lower or equal
      [priorities](#module-priority) are executed for `key`. If worker (queue
      holder) was not spawned for `key` — value is fetched *immediately*;

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> import AgentMap
      iex> import :timer
      ...>
      iex> am = AgentMap.new(a: 1)
      iex> fetch(am, :a)
      {:ok, 1}
      iex> fetch(am, :b)
      :error
      iex> am
      ...> |> cast(:b, fn _ -> sleep(20); 42 end)
      ...> |> fetch(:b)
      :error
      iex> am
      ...> |> fetch(:b, !: :min)
      {:ok, 42}
  """
  @spec fetch(am, key, keyword | timeout) :: {:ok, value} | :error
  def fetch(am, key, opts \\ [!: :now]) do
    defs = [!: :now]
    opts = prepair(opts, defs, forbid: [:break, :drop])

    req = %Req{action: :fetch, key: key}

    _call(am, struct(req, opts))
  end

  @doc """
  Fetches the value for a specific `key`, erroring out otherwise.

  Returns current value *immediately*, unless `!: priority` is provided. If
  `key` is not present — raises a `KeyError`.

  ## Options

    * `:!` (`priority`) — to wait until calls with a lower or equal
      [priorities](#module-priority) are executed for `key`. If worker (queue
      holder) was not spawned for `key` — value is fetched *immediately*;

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.fetch!(am, :a)
      1
      iex> AgentMap.fetch!(am, :b)
      ** (KeyError) key :b not found

      iex> import :timer
      ...>
      iex> AgentMap.new()
      ...> |> AgentMap.cast(:a, fn nil -> sleep(10); 42 end)
      ...> |> AgentMap.fetch!(:a, !: :min)
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

  @doc """
  Returns whether the given `key` exists.

  Syntactic sugar for

      match?({:ok, _}, fetch(am, key, opts))

  ## Options

    * `:!` (`priority`) — to put this call in a queue with given
      [priority](#module-priority);

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.has_key?(am, :a)
      true
      iex> AgentMap.has_key?(am, :b)
      false
  """
  @spec has_key?(am, key, keyword | timeout) :: boolean
  def has_key?(am, key, opts \\ [!: :now]) do
    match?({:ok, _}, fetch(am, key, opts))
  end

  @doc """
  Removes and returns the value associated with `key`.

  If there is no such `key`, `default` is returned (`nil`).

  ## Options

    * `:!` (`priority`, `:avg`) — to put this call in a queue with given
      [priority](#module-priority);

    * `timeout: {:drop, pos_integer}` — to drop this call from queue after given
      number of milliseconds;

    * `timeout: {:drop, pos_integer}` — drops this call from queue when
      [timeout](#module-timeout) occurs;

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> am =
      ...>   AgentMap.new(a: 42, b: nil)
      ...>
      iex> AgentMap.pop(am, :a)
      42
      iex> AgentMap.pop(am, :a)
      nil
      iex> AgentMap.pop(am, :a, :error)
      :error
      iex> AgentMap.pop(am, :b, :error)
      nil
      iex> AgentMap.pop(am, :b, :error)
      :error
      iex> Enum.empty?(am)
      true
  """
  @spec pop(am, key, any, keyword | timeout) :: value | any
  def pop(am, key, default \\ nil, opts \\ []) do
    defs = [!: :now]
    opts = prepair(opts, defs, forbid: [:break])

    fun = fn _ ->
      if Process.get(:value) do
        :pop
      end || {default}
    end

    get_and_update(am, key, fun, opts)
  end

  @doc """
  Puts the given `value` under `key`.

  Returns *immediately*, without waiting for the actual put to occur.

  Default [priority](#module-priority) for this call is `:max`.

  ## Options

    * `cast: false` — to return only when the actual put occur;

    * `:timeout` (`pos_integer | :infinity`, `5000`). The option is ignored if
      `cast: true` is used (by default);

    * `timeout: {:drop, pos_integer}` — to drop `fun` from queue upon the
      occurence of [timeout](#module-timeout);

    * `:!` (`priority`, `:max`) — to put this call in a queue with given
      [priority](#module-priority). If worker (queue holder) was not spawned for
      `key`, the value is replaced *immediately*.

  ## Examples

      iex> import AgentMap
      ...>
      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> put(:a, 42)
      ...> |> put(:b, 42)
      ...> |> take([:a, :b])
      %{a: 42, b: 42}

  This function will not spawn worker for `key`, if there are no queue of calls
  awaiting for invocation. So in this case `cast: false` is not used, since
  take-call cannot occur before any of the actual puts (no race condition
  possible).

      iex> Process.flag(:trap_exit, true)
      ...>
      iex> import AgentMap
      ...>
      iex> am =
      ...>   %{a: 1}
      ...>   |> AgentMap.new()
      ...>   |> sleep(:a, 20)
      ...>   |> put(:a, 42)
      ...>   |> put(:a, 0, !: :avg)
      ...>   |> put(:a, 1, !: :avg, timeout: {:drop, 10})
      ...>
      iex> fetch(am, :a)          # ⏺ ⟶ s ⟶ p ⟶ p ⟶̸ p̶
      {:ok, 1}
      iex> fetch(am, :a, !: :max) # s ⟶ p ⟶ ⏺ ⟶ p ⟶̸ p̶
      {:ok, 42}
      iex> fetch(am, :a, !: :min) # s ⟶ p ⟶ p ⟶ ⏺ ⟶̸ p̶
      {:ok, 0}
  """
  @spec put(am, key, value, keyword) :: am
  def put(am, key, value, opts \\ [!: :max, cast: true]) do
    defs = [!: :max, cast: true]
    opts = prepair(opts, defs, forbid: [:break])

    req = %Req{action: :put, key: key, data: value} |> struct(opts)

    if opts[:cast] do
      GenServer.cast(pid(am), req)
    else
      _call(am, req)
    end

    am
  end

  @doc """
  Puts the given `value` under `key`, unless the entry already exists.

  Returns *immediately*, without waiting for the actual put to occur.

  Default [priority](#module-priority) for this call is `:max`.

  See `put/4`.

  ## Options

    * `cast: false` — to return only when the actual put occur;

    * `:timeout` (`pos_integer | :infinity`, `5000`). The option is ignored if
      `cast: true` is used (by default);

    * `timeout: {:drop, pos_integer}` — to drop `fun` from queue upon the
      occurence of [timeout](#module-timeout);

    * `:!` (`priority`, `:max`) — to put this call in a queue with given
      [priority](#module-priority). If worker (queue holder) was not spawned for
      `key`, the value is replaced *immediately*.

  ## Examples

      iex> import AgentMap
      ...>
      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> put_new(:a, 42)
      ...> |> put_new(:b, 42)
      ...> |> take([:a, :b])
      %{a: 1, b: 42}

  This function will not spawn worker for `key`, if there are no queue of calls
  awaiting for invocation. So in this case `cast: false` is not used, since
  take-call cannot occur before any of the actual puts (no race condition
  possible).
  """
  @spec put_new(am, key, value, keyword) :: am
  def put_new(am, key, value, opts \\ [priority: :max, cast: true]) do
    defs = [priority: :max, cast: true]
    opts = prepair(opts, defs, forbid: [:break])

    req = %Req{action: :put_new, key: key, data: value} |> struct(opts)

    if opts[:cast] do
      GenServer.cast(pid(am), req)
    else
      _call(am, req)
    end

    am
  end

  @doc """
  Evaluates `fun` and puts the result under `key`, unless it is already present.

  Returns *immediately*, without waiting for the actual put to occur.

  This function is useful in case you want to compute the value to put under
  `key` only if it is not already present (e.g., the value is expensive to
  calculate or generally difficult to setup and teardown again).

  Default [priority](#module-priority) for this call is `:max`.

  See `put_new/4`.

  ## Options

    * `cast: false` — to return only when the actual put occur;

    * `:timeout` (`pos_integer | :infinity`, `5000`). The option is ignored if
      `cast: true` is used (by default);

    * `timeout: {:drop, pos_integer}` — to drop `fun` from queue upon the
      occurence of [timeout](#module-timeout);

    * `timeout: {:break, pos_integer}` — to drop `fun` from queue or break a
      running `fun` upon the occurence of [timeout](#module-timeout);

    * `:!` (`priority`, `:max`) — to put this call in a queue with given
      [priority](#module-priority).

  ## Examples

      iex> import AgentMap
      ...>
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
  def put_new_lazy(am, key, fun, opts \\ [priority: :max, cast: true]) do
    defs = [priority: :max, cast: true]
    opts = prepair(opts, defs, forbid: [:break])

    req = %Req{action: :put_new, key: key, fun: fun} |> struct(opts)

    if opts[:cast] do
      GenServer.cast(pid(am), req)
    else
      _call(am, req)
    end

    am
  end

  @doc """
  Deletes the entry for `key`.

  Returns *immediately*, without waiting for the actual delete to occur.

  Default [priority](#module-priority) for this call is `:max`.

  ## Options

    * `cast: false` — to return only when the actual drop occur;

    * `:timeout` (`pos_integer | :infinity`, `5000`). Is ignored if `cast: true`
      option is given (by default);

    * `timeout: {:drop, pos_integer}` — to drop call from queue upon the
      occurence of [timeout](#module-timeout);

    * `:!` (`priority`, `:max`) — to put this call in a queue with given
      [priority](#module-priority). If worker (queue holder) was not spawned for
      `key`, the value is deleted *immediately*.

  ## Examples

      iex> %{a: 1, b: 2}
      ...> |> AgentMap.new()
      ...> |> AgentMap.delete(:a)
      ...> |> AgentMap.take([:a, :b])
      %{b: 2}
  """
  @spec delete(am, key, keyword) :: am
  def delete(am, key, opts \\ [cast: true, !: :max]) do
    defs = [cast: true, !: :max]
    opts = prepair(opts, defs, forbid: [:break])

    req = %Req{action: :delete, key: key} |> struct(opts)

    if opts[:cast] do
      GenServer.cast(pid(am), req)
    else
      _call(am, req)
    end

    am
  end

  @doc """
  Drops given `keys`.

  Returns *immediately*, without waiting for the actual drop to occur.

  Default [priority](#module-priority) for this call is `:max`.

  ## Options

    * `cast: false` — to return only when the actual drop occur;

    * `:timeout` (`pos_integer | :infinity`, `5000`). Is ignored if `cast: true`
      option is given (by default);

    * `timeout: {:drop, pos_integer}` — to cancel delete upon the occurence of
      [timeout](#module-timeout). On cancel, if delete happen for some key, its
      value will remain deleted;

    * `:!` (`priority`, `:max`) — to set up [priorities](#module-priority) for
      delete calls. If workers (queue holders) are not spawned for some of the
      `keys`, values for them are deleted *immediately*.

  ## Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.drop([:b, :d])
      ...> |> AgentMap.take([:a, :b, :c])
      %{a: 1, c: 3}

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.drop([:b, :d])
      ...> |> AgentMap.keys()
      [:a, :c]
  """
  @spec drop(am, Enumerable.t(), keyword) :: am
  def drop(am, keys, opts \\ [cast: true, !: :max]) do
    defs = [cast: true, !: :max]
    opts = prepair(opts, defs, forbid: [:break])

    if opts[:cast] do
      req = struct(%Req{action: :drop}, opts)
      GenServer.cast(am, req)
    else
      Multi.update(am, keys, fn _ -> :drop end, opts)
    end

    am
  end

  @doc """
  Returns *immediately* a map representation of an `AgentMap`.

  ## Options

    * `:!` (`priority`) — to wait until calls with a lower or equal priorities
      are executed;

    * `:timeout` (`pos_integer | :infinity`, `5000`).

  ## Examples

      iex> %{a: 1, b: 2, c: nil}
      ...> |> AgentMap.new()
      ...> |> AgentMap.to_map()
      %{a: 1, b: 2, c: nil}
  """
  @spec to_map(am, keyword | timeout) :: %{required(key) => value}
  def to_map(am, opts \\ []) do
    defs = [!: :now]
    opts = prepair(opts, defs, forbid: [:break, :drop])

    req = struct(%Req{action: :to_map}, opts)
    _call(am, req)
  end

  @doc """
  Returns a key-value pairs.

  Keys that do not exist are ignored.

  ## Options

    * `:!` (`priority`, `:avg`) — to put this call in a queue with given
      [priority](#module-priority). If workers (queue holders) are not spawned
      for some of the `keys`, values for them are returned *immediately*;

    * `!: :now` — to return *immediately* a snapshot with keys and values;

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> import AgentMap
      iex> import :timer
      ...>
      iex> am =
      ...>   %{a: 1, b: 2, c: 3}
      ...>   |> AgentMap.new()
      ...>   |> cast(:a, fn _ -> sleep(10); 42 end)
      ...>   |> cast(:b, fn _ -> sleep(10); 42 end)
      ...>   |> put(:a, 0)
      ...>
      iex> take(am, [:a, :b], !: :now)
      %{a: 1, b: 2}
      iex> take(am, [:a, :b, :d])
      %{a: 0, b: 42}
  """
  @spec take(am, [key], keyword | timeout) :: map
  def take(am, keys, opts \\ [!: :avg]) do
    defs = [!: :avg]
    opts = prepair(opts, defs, forbid: [:break, :drop])

    fun = fn _ -> Process.get(:map) end
    Multi.get(am, keys, fun, opts)
  end

  @doc """
  Returns all keys.

  ## Examples

      iex> %{a: 1, b: nil, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.keys()
      [:a, :b, :c]
  """
  @spec keys(am) :: [key]
  def keys(am), do: _call(am, %Req{action: :keys, !: :now})

  @doc """
  Returns *immediately* all current values of an `AgentMap`.

  ## Options

    * `:!` (`priority`) — to wait until calls with a lower or equal
      [priorities](#module-priority) are executed;

    * `:timeout` (`timeout`, `5000`).

  ## Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.values()
      [1, 2, 3]

      iex> import AgentMap
      iex> import :timer
      ...>
      iex> am =
      ...>   %{a: 1, b: 2, c: 42}
      ...>   |> AgentMap.new()
      ...>   |> cast(:a, fn _ -> sleep(10); 42 end)
      ...>   |> cast(:b, fn _ -> sleep(10); 42 end)
      ...>   |> put(:a, 0)
      ...>
      iex> values(am, !: :max)
      [42, 42, 42]
      iex> values(am, !: :min)
      [0, 42, 42]
  """
  @spec values(am, keyword | timeout) :: [value]
  def values(am, opts \\ []) do
    defs = [!: :now]
    opts = prepair(opts, defs, forbid: [:break, :drop])

    fun = fn _ ->
      Map.values(Process.get(:map))
    end

    Multi.get(am, keys(am), fun, opts)
  end

  @doc """
  Increments value with given `key`.

  By default, returns *immediately*, without waiting for the actual increment to
  occur.

  This call raises an `ArithmeticError` for a non-numeric values.

  ### Options

    * `:initial` (`number`, `0`) — if value does not exist it is considered to
      be the one given as initial;

    * `initial: false` — raises `KeyError` if value does not exist;

    * `:step` (`number`, `1`) — increment step;


    * `cast: false` (`boolean`, `true`) — to return only when the actual
      increment occur;

    * `timeout: {:drop, pos_integer}` — to drop this call from queue after given
      number of milliseconds;

    * `:timeout` (`timeout`, `5000`). Is ignored if `cast: true` is given;

    * `:!` (`priority`, `:avg`) — to put this call in a queue with given
      [priority](#module-priority).

  ### Examples

      iex> am = AgentMap.new(a: 1.5)
      iex> am
      ...> |> inc(:a, step: 1.5)
      ...> |> inc(:b)
      ...> |> get(:a)
      3
      iex> am
      ...> |> get(:b)
      1
      iex> am
      ...> |> inc(:c, initial: false)
      ** (KeyError) key :c not found

      iex> import :timer
      ...>
      iex> AgentMap.new()
      ...> |> cast(:a, fn nil -> sleep(10); 1 end) # 1
      ...> |> cast(:a, fn 2 -> 3 end)              # 3
      ...> |> inc(:a, !: :max)                     # 2
      ...> |> get(:a)
      3
  """
  @spec inc(am, key, keyword) :: am
  def inc(am, key, opts \\ [step: 1, cast: true, initial: 0]) do
    defs = [step: 1, cast: true, initial: 0, !: :avg]
    opts = prepair(opts, defs, forbid: [:break])

    step = opts[:step]
    initial = opts[:initial]

    fun = fn
      v when is_number(v) ->
        {:ok, v + step}

      v ->
        if Process.get(:value) do
          raise IncError, key: key, value: v, step: step
        else
          if initial do
            {:ok, initial + step}
          else
            raise KeyError, key: key
          end
        end
    end

    req = %Req{action: :get_and_update, key: key, fun: fun} |> struct(opts)

    if opts[:cast] do
      GenServer.cast(pid(am), req)
    else
      _call(am, req)
    end

    am
  end

  @doc """
  Decrements value for `key`.

  Syntactic sugar for

      inc(am, key, update(opts, :step, -1, & -&1))

  See `inc/3` for details.
  """
  @spec dec(am, key, keyword) :: am
  def dec(am, key, opts \\ [step: 1, cast: true, initial: 0, !: :avg]) do
    opts = Keyword.update(opts, :step, -1, &(-&1))
    inc(am, key, opts)
  end

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

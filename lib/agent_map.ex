defmodule AgentMap do
  @enforce_keys [:pid]
  defstruct @enforce_keys

  alias AgentMap.{Server, Req, IncError, Multi, Worker}

  import Worker, only: [dict: 1]

  @moduledoc """
  The `AgentMap` can be seen as a stateful `Map` that parallelize operations
  made on different keys. Basically, it can be used as a cache, memoization,
  computational framework and, sometimes, as a `GenServer` replacement.

  Underneath it's a `GenServer` that holds a `Map`. When an `update/4`,
  `update!/4`, `get_and_update/4` or `cast/4` is first called for a key, a
  special temporary process called "worker" is spawned. All subsequent calls for
  that key will be forwarded to the message queue of this worker. This process
  respects the order of incoming new calls, executing them in a sequence, except
  for the `get/4` calls, which are processed as a parallel `Task`s. For each
  key, the degree of parallelization can be tweaked using the `max_processes/3`
  function. The worker will die after about `10` ms of inactivity.

  The `AgentMap` supports multi-key calls — operations made on a group of keys.
  See `AgentMap.Multi`.

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

  The special struct `%AgentMap{}` can be created via the `new/1` function. This
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

  The `AgentMap` provides possibility to make multi-key calls (operations on
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

  ### Priority calls (`!: true`)

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
      iex> AgentMap.new(state: :ready)
      ...> |> cast(:state, fn :ready  -> sleep(10); :steady end)
      ...> |> cast(:state, fn :go!    -> sleep(10); :stop end)
      ...> |> cast(:state, fn :steady -> sleep(10); :go! end, !: true) # priority call
      ...> |> fetch(:state)
      {:ok, :ready}

  — the third one `cast/4` is a priority call, and so takes the `steady` value
  as an argument (not `stop`).

  ### Timeout

  Timeout is an integer greater than zero which specifies how many milliseconds
  are allowed before the `agentmap` executes the `fun` and returns a result, or
  an atom `:infinity` to wait indefinitely. If no result is received within the
  specified time, the caller exits. By default it is set to the `5000 ms` = `5
  sec`.

  If no result is received within the specified time, the caller exits, (!) but
  the callback will remain in a queue! To change this behaviour, provide
  `timeout: {:drop, pos_integer}` as a value.

      iex> import AgentMap
      ...> #
      iex> Process.flag(:trap_exit, true)
      iex> Process.info(self())[:message_queue_len]
      0
      iex> AgentMap.new(key: 42)
      ...> |> cast(:key, &(:timer.sleep(15) && &1))
      ...> |> put(:key, 24, timeout: 10)
      ...> |> put(:key, 33, timeout: {:drop, 10})
      ...> |> fetch(:key, !: false)
      {:ok, 24}
      iex> Process.info(self())[:message_queue_len]
      2

  The second `put/4` was never executed because it was dropped from queue,
  although, `GenServer` exit signal will be send.

  If timeout happen while callback is executed — it will not be interrupted. For
  this special case `timeout: {:break, pos_integer}` option exist that instructs
  `AgentMap` to wrap call in a `Task`. In the

      cast(am, :key, &(sleep(:infinity) && &1), timeout: {:break, 6000})

  call, callback is wrapped in a `Task` which has `6` sec before *shutdown*.

  ## Name registration

  An agentmap is bound to the same name registration rules as `GenServers`, see
  the `GenServer` documentation for details.

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

  See the `Supervisor` docs for more information.
  """

  @max_processes 5

  @typedoc "Return values for the `start` and `start_link` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid} | term}

  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "The `AgentMap` server (name, link, pid, …)"
  @type agentmap :: pid | {atom, node} | name | %AgentMap{}
  @type am :: agentmap

  @type key :: term
  @type value :: term

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

  ## HELPERS ##

  @doc """
  PID of an `AgentMap` server.
  """
  def pid(%__MODULE__{pid: p}), do: p
  def pid(p), do: p

  @doc """
  Wraps the `fun` in the `try…catch` before applying `args`.

  Returns `{:ok, reply}`, `{:error, :badfun}` or `{:error, :badarity}`.

  ## Examples

      iex> import AgentMap
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
  Returns a new `agentmap`.

  ## Examples

      iex> am = AgentMap.new()
      iex> Enum.empty?(am)
      true
  """
  @spec new :: agentmap
  def new, do: new(%{})

  @doc """
  Starts an `AgentMap` via `start_link/1` function. `new/1` returns `AgentMap`
  *struct* that contains PID of the `AgentMap`.

  As the argument, keyword with states can be provided or the PID of an already
  started agentmap.

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

  def new(%__MODULE__{} = am), do: am
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
  Creates agentmap from an `enumerable` via the given transformation function.

  Duplicated keys are removed; the latest one prevails.

  ## Examples

      iex> AgentMap.new([:a, :b], &{&1, :a})
      ...> |> AgentMap.take([:a, :b])
      %{a: :a, b: :a}
  """
  @spec new(Enumerable.t(), (term -> {key, value})) :: am
  def new(enumerable, transform) do
    new(Map.new(enumerable, transform))
  end

  # Common for start_link/1 and start/1
  # separate GenServer options and funs.
  defp separate(funs_and_opts) do
    {opts, funs} =
      funs_and_opts
      |> Enum.reverse()
      |> Enum.split_while(fn {k, _} ->
        k in [:name, :timeout, :debug, :spawn_opt, :max_processes]
      end)

    {Enum.reverse(funs), opts}
  end

  defp prepair(funs_and_opts) do
    {funs, opts} = separate(funs_and_opts)

    args = [
      funs: funs,
      timeout: opts[:timeout] || 5000,
      max_processes: opts[:max_processes] || @max_processes
    ]

    # Global timeout must be turned off.
    gen_server_opts =
      opts
      |> Keyword.put(:timeout, :infinity)
      |> Keyword.delete(:max_processes)

    {args, gen_server_opts}
  end

  @doc """
  Starts an `AgentMap` server linked to the current process with the given
  function.

  The single argument is a keyword combined of a pairs `{key, fun/0}`, and, at
  the end, of a `GenServer.options` pairs. For each key, fun is executed in a
  separate `Task`.

  ## Options

    * `:name` — (any) if present, is used for registration as described in the
    module documentation;

    * `:debug` — if present, the corresponding function in the [`:sys`
    module](http://www.erlang.org/doc/man/sys.html) will be invoked;

    * `:spawn_opt` — if present, its value will be passed as options to the
    underlying process as in `Process.spawn/4`;

    * `:timeout` — (`pos_integer | :infinity`, `5000`) the `agentmap` is allowed
    to spend at most the given number of milliseconds on the whole process of
    initialization or it will be terminated and the start function will return
    `{:error, :timeout}`.

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

  — starts server with a predefined single key `:k`.

      iex> AgentMap.start(k: 3)
      {:error, k: :badfun}
      iex> AgentMap.start(k: & &1)
      {:error, k: :badarity}
      iex> {:error, k: {exc, _st}} =
      ...>   AgentMap.start(k: fn -> raise "oops" end)
      iex> exc
      %RuntimeError{message: "oops"}
  """
  @spec start_link([{key, (() -> any)} | GenServer.option()]) :: on_start
  def start_link(funs_and_opts \\ [timeout: 5000]) do
    {args, opts} = prepair(funs_and_opts)
    GenServer.start_link(Server, args, opts)
  end

  @doc """
  Starts an `AgentMap` as an unlinked process.

  See `start_link/2` for details.

  ## Examples

      iex> import :timer
      iex> err = AgentMap.start(a: 42,
      ...>                      b: fn -> sleep(:infinity) end,
      ...>                      c: fn -> raise "oops" end,
      ...>                      timeout: 10)
      iex> {:error, a: :badfun, b: :timeout, c: {exc, _st}} = err
      iex> exc
      %RuntimeError{message: "oops"}
  """
  @spec start([{key, (() -> any)} | GenServer.option()]) :: on_start
  def start(funs_and_opts \\ [timeout: 5000]) do
    {args, opts} = prepair(funs_and_opts)
    GenServer.start(Server, args, opts)
  end

  @doc false
  def _call(agentmap, req, opts \\ [])

  def _call(agentmap, req, opts) when is_list(opts) do
    am = pid(agentmap)
    req = struct(req, opts)

    case opts[:timeout] do
      {_, t} ->
        GenServer.call(am, req, t)

      t ->
        GenServer.call(am, req, t || 5000)
    end
  end

  def _call(agentmap, req, t), do: _call(agentmap, req, timeout: t)

  defp _cast(agentmap, %Req{} = req, opts \\ []) do
    am = pid(agentmap)
    req = struct(req, opts)

    GenServer.cast(am, req)
    agentmap
  end

  ##
  ## GET
  ##

  @doc """
  Gets an `agentmap` value via the given `fun`.

  The function `fun` is sent to the `agentmap` which invokes it, passing the
  value associated with `key` (or `nil`). The result of the invocation is
  returned from this function. This call does not change value, so a series of
  `get`-calls can and will be executed as a parallel `Task`s (see
  `max_processes/3`).

  If there are callbacks awaiting invocation, this `fun` will be added to the
  end of the corresponding queue. If `!: true` option is given, `fun` will be
  executed *immediately*, passing current value as an argument. Thus, any number
  of `get(…, …, …, !: true)` calls will be executed concurently, no matter of
  what `max_processes` value is provided for the `key`.

  ## Options

    * `!: true` — (`boolean`, `false`) to make [priority
      calls](#module-priority-calls-true). The `key` could have an associated
      queue of callbacks awaiting of execution, "priority" version allows to
      execute given `fun` immediately in a separate `Task`, providing the
      current value as an argument.

      This calls are not counted in a number of processes allowed to run in
      parallel (see `max_processes/3`):

          iex> import AgentMap
          iex> #
          ...> am = AgentMap.new()
          iex> info(am, :k)[:max_processes]
          5
          #
          iex> for _ <- 1..100 do
          ...>   Task.async(fn ->
          ...>     get(am, :k, &(:timer.sleep(40) && &1), !: true)
          ...>   end)
          ...> end
          iex> sleep(10)
          iex> info(am, :k)[:processes] > 5
          true

    * `timeout: {:drop, pos_integer}` — to throw out `fun` from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `timeout: {:break, pos_integer}` — to throw out `fun` from queue or cancel
      a running `fun` upon the occurence of a timeout. See [timeout
      section](#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`).

  ## Examples

      iex> import AgentMap
      iex> am = AgentMap.new()
      iex> get(am, :Alice, & &1)
      nil
      iex> am
      ...> |> put(:Alice, 42)
      ...> |> get(:Alice, & &1 + 1)
      43

  "Priority" calls:

      iex> import AgentMap
      iex> am = AgentMap.new(Alice: 42)
      iex> am
      ...> |> cast(:Alice, &(:timer.sleep(40) && &1 + 1))
      ...> |> get(:Alice, & &1, !: true)
      42
      iex> get(am, :Alice) # the same
      42
      iex> get(am, :Alice, & &1) # !: false
      43
      iex> get(am, :Alice, & &1, !: true)
      43

  ## Special process dictionary keys

  One can use `:key` and `:value` dictionary keys:

      iex> import AgentMap
      iex> am = AgentMap.new(Alice: nil)
      iex> get(am, :Alice, fn _ ->
      ...>   Process.get(:key)
      ...> end)
      :Alice
      iex> get(am, :Alice, fn nil ->
      ...>   Process.get(:value)
      ...> end)
      {:value, nil}
      iex> get(am, :Bob, fn nil ->
      ...>   Process.get(:value)
      ...> end)
      nil
  """
  @spec get(am, key, (value -> get), keyword | timeout) :: get when get: var
  def get(agentmap, key, fun, opts \\ []) do
    req = %Req{action: :get, key: key, fun: fun}
    _call(agentmap, req, opts)
  end

  # 2

  @doc """
  *Immediately* returns the current value for the given `key` in `AgentMap`.

  ## Examples

      iex> am = AgentMap.new(Alice: 42)
      iex> AgentMap.get(am, :Alice)
      42
      iex> AgentMap.get(am, :Bob)
      nil
  """
  @spec get(am, key) :: value | nil
  def get(agentmap, key) do
    case fetch(agentmap, key) do
      {:ok, value} ->
        value

      :error ->
        nil
    end
  end

  @doc """
  Gets the value for a specific `key` in `agentmap`.

  If `key` is present in `agentmap` with value `value`, then `value` is
  returned. Otherwise, `fun` is evaluated and its result is returned.

  This is useful if the default value is very expensive to calculate or
  generally difficult to setup and teardown again.

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
  @spec get_lazy(am, key, (() -> a)) :: value | a when a: var
  def get_lazy(agentmap, key, fun) do
    cb = fn value ->
      if Process.get(:value) do
        value
      else
        fun.()
      end
    end

    get(agentmap, key, cb)
  end

  ##
  ## GET_AND_UPDATE
  ##

  @doc """
  Gets the value for `key` in `agentmap` and updates it, all in one pass.

  The function `fun` is sent to the `agentmap` which invokes it, passing the
  value associated with `key` (or `nil`). The result of an invocation is
  returned from this function.

  A `fun` can return:

    * a two element tuple: `{"get" value, new value}`;
    * a one element tuple `{"get" value}` — the value is not changed;
    * `:pop` — similar to `Map.get_and_update/3` this returns value with given
      `key` and removes it from `agentmap`;
    * `:id` to return a current value, while not changing it.

  For example, `get_and_update(account, :Alice, & {&1, &1 + 1_000_000})` returns
  the balance of `:Alice` and makes the deposit, while `get_and_update(account,
  :Alice, & {&1})` just returns the balance.

  ## Options

    * `!: true` — (`boolean`, `false`) to make [priority
      calls](#module-priority-calls-true). The `key` could have an associated
      queue of callbacks, awaiting of execution. If such queue exists, asks a
      worker to process the `fun` in the prioriry order;

    * `timeout: {:drop, pos_integer}` — to throw out `fun` from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `timeout: {:break, pos_integer}` — to throw out `fun` from queue or cancel
      `fun` that is already running, upon the occurence of a timeout. See
      [timeout section](#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`).

  ## Examples

      iex> import AgentMap
      iex> am = new(k: 22)
      iex> get_and_update(am, :k, & {&1, &1 + 1})
      22
      iex> get(am, :k)
      23
      iex> get_and_update(am, :k, fn _ -> :pop end)
      23
      iex> has_key?(am, :k)
      false
      iex> get_and_update(am, :k, fn _ -> :id end)
      nil
      iex> has_key?(am, :k)
      false
      iex> get_and_update(am, :k, fn v -> {v, v} end)
      nil
      iex> has_key?(am, :k)
      true
  """
  # 4
  @spec get_and_update(am, key, (value -> {get} | {get, value} | :pop | :id), keyword | timeout) ::
          get | value
        when get: var
  def get_and_update(agentmap, key, fun, opts \\ [!: false, timeout: 5000]) do
    req = %Req{action: :get_and_update, key: key, fun: fun}
    _call(agentmap, req, opts)
  end

  ##
  ## UPDATE
  ##

  @doc """
  Updates the `key` in `agentmap` with the given `fun`.

  Returns `agentmap` to support piping.

  Syntactic sugar for

      get_and_update(agentmap, key, &{agentmap, fun.(&1)}, opts)

  See `get_and_update/4`.

  ## Options

  The same as for `get_and_update/4`.

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
  def update(agentmap, key, fun, opts \\ [!: false, timeout: 5000])

  @spec update(am, key, value, (value -> value)) :: am
  def update(agentmap, key, initial, fun) when is_function(fun, 1) do
    update(agentmap, key, initial, fun, 5000)
  end

  def update(agentmap, key, fun, opts) when is_function(fun, 1) do
    get_and_update(agentmap, key, &{agentmap, fun.(&1)}, opts)
  end

  @doc """
  This call exists as a copy of `Map.update/4`.

  Returns `agentmap` to support piping.

  See `update/4`.

  ## Options

  The same as for the `get_and_update/4` call.

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
  def update(agentmap, key, initial, fun, opts) do
    fun = fn value ->
      if Process.get(:value) do
        fun.(value)
      end || initial
    end

    update(agentmap, key, fun, opts)
  end

  @doc """
  Updates `key` with the given function.

  If `key` is present in `agentmap`, `fun` is invoked with value as argument and
  its result is used as the new value of `key`. If `key` is not present in
  `agentmap`, a `KeyError` exception is raised.

  Returns `agentmap` to support piping.

  See `update/4`.

  ## Options

  The same as for the `get_and_update/4` call.

  ## Examples

      iex> import AgentMap
      iex> #
      ...> am = AgentMap.new(Alice: 1)
      iex> am
      ...> |> cast(:Alice, fn 1 -> :timer.sleep(20); 2 end)
      ...> |> cast(:Alice, fn 3 -> 4 end)
      ...> |> update!(:Alice, fn 4 -> 5 end)
      ...> |> update!(:Alice, fn 2 -> 3 end, !: true)
      ...> |> fetch(:Alice, !: false)
      {:ok, 5}
      #
      iex> update!(am, :Bob, & &1)
      ** (KeyError) key :Bob not found
  """
  @spec update!(am, key, (value -> value), keyword | timeout) :: am
  def update!(agentmap, key, fun, opts \\ [!: false, timeout: 5000])

  def update!(agentmap, key, fun, opts) when is_list(opts) do
    fun = fn value ->
      if Process.get(:value) do
        {:ok, fun.(value)}
      end || {:error}
    end

    res = get_and_update(agentmap, key, fun, opts)

    if :ok == res do
      agentmap
    else
      raise KeyError, key: key
    end
  end

  def update!(agentmap, key, fun, t) do
    update!(agentmap, key, fun, timeout: t)
  end

  @doc """
  Alters the value stored under `key`, but only if `key` already exists in
  `agentmap`.

  If `key` is not present in `agentmap`, a `KeyError` exception is raised.
  Returns `agentmap` to support piping.

  Syntactic sugar for

      update!(agentmap, key, fn _ -> value end, opts)

  See `update!/4`.

  ## Options

    * `!: true` — (`boolean`, `false`) to alter value as fast as possible,
      making this call a [priority](#module-priority-calls-true);

    * `timeout: {:drop, pos_integer}` — to cancel replacement upon the occurence
      of a timeout. See [timeout section](#module-timeout);

    * `timeout` — (`pos_integer | :infinity`, `5000`)

  ## Examples

      iex> import AgentMap
      iex> #
      ...> am = AgentMap.new(a: 1, b: 2)
      iex> am
      ...> |> replace!(:a, 3)
      ...> |> values()
      [3, 2]
      iex> am
      ...> |> replace!(:c, 2)
      ** (KeyError) key :c not found
  """
  @spec replace!(agentmap, key, value, keyword | timeout) :: agentmap
  def replace!(agentmap, key, value, opts \\ [!: false, timeout: 5000])

  def replace!(agentmap, key, value, opts) when is_list(opts) do
    if match?({:break, _}, opts[:timeout]) do
      raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable here."
    end

    update!(agentmap, key, fn _ -> value end, opts)
  end

  def replace!(agentmap, key, value, t) do
    replace!(agentmap, key, value, timeout: t)
  end

  ##
  ## CAST
  ##

  @doc """
  Performs `cast` ("fire and forget"). Works the same as `update/4`, but uses
  `GenServer.cast/2`.

  Returns *immediately* the same `agentmap` to support piping.

  ## Special process dictionary keys

  Are the same as for `get_and_update/4`.

  ## Options

    * `!: true` — (`boolean`, `false`) to update value as fast as possible,
      making this call a [priority](#module-priority-calls-true);

    * `timeout: {:break, pos_integer}` — to throw out `fun` from queue or cancel
      `fun` that is already running, upon the occurence of a timeout. See
      [timeout section](#module-timeout);

    * `timeout: {:drop, pos_integer}` — to cancel replacement upon the occurence
      of a timeout. See [timeout section](#module-timeout).

  Caller will not receive exit signal when timeout happens.
  """
  @spec cast(am, key, (value -> value), keyword) :: am
  def cast(agentmap, key, fun, opts \\ [!: false]) do
    req = %Req{action: :get_and_update, key: key, fun: &{:_get, fun.(&1)}}
    _cast(agentmap, req, opts)
  end

  @doc """
  Returns the default `:max_processes` value.

  See `max_processes/3`.

  ## Examples

      iex> import AgentMap
      iex> #
      ...> am = AgentMap.new()
      iex> max_processes(am)
      5
      iex> max_processes(am, :infinity)
      iex> :timer.sleep(10)
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
  @spec max_processes(agentmap) :: pos_integer | :infinity
  def max_processes(agentmap) do
    dict(pid(agentmap))[:max_processes]
  end

  @doc """
  Sets the default `:max_processes` value. Returns the same `agentmap` to
  support piping.

  See `max_processes/3`.

  ## Examples

      iex> import AgentMap
      iex> #
      ...> am = AgentMap.new()
      iex> max_processes(am)
      5
      iex> max_processes(am, :infinity)
      iex> :timer.sleep(10)
      iex> max_processes(am)
      :infinity
  """
  @spec max_processes(am, pos_integer | :infinity) :: am
  def max_processes(agentmap, value)
      when (is_integer(value) and value > 0) or value == :infinity do
    _cast(agentmap, %Req{action: :g_max_processes, data: value})
  end

  @doc """
  Sets the `:max_processes` value for the given `key`.

  Returns the same `agentmap` to support piping.

  The `Agentmap` can execute `get/4` calls on the same key concurrently.
  `max_processes` option specifies number of processes allowed per key, `-1` for
  the worker process if it is spawned.

  By default, `5` get-processes per key allowed, but this can be changed via
  `max_processes/2`.

      iex> import AgentMap
      iex> #
      ...> am = AgentMap.new(k: 42)
      iex> task = fn ->
      ...>   get(am, :k, fn _ -> :timer.sleep(10) end)
      ...> end
      iex> for _ <- 1..4, do: spawn(task)
      iex> task.()
      :ok

  will be executed in around of `10` ms, not `50`. This sequence:

      AgentMap.new(k: 42)
      |> get(:k, fn _ -> sleep(10) end)
      |> cast(:k, fn _ -> sleep(10) end)
      |> cast(:k, fn _ -> sleep(10) end)

  will run for `20` ms as `AgentMap` can parallelize any sequence of `get/3`
  calls ending with `get_and_update/3`, `update/3` or `cast/3`.

  Use `max_processes: 1` to execute `get` calls in a sequence.

  ## Examples

      iex> import :timer
      iex> import AgentMap
      iex> #
      ...> am = AgentMap.new()
      iex> max_processes(am, :key, 42)
      #
      iex> for _ <- 1..1000 do
      ...>   Task.async(fn ->
      ...>     get(am, :key, fn _ -> sleep(10) end)
      ...>   end)
      ...> end
      iex> #
      ...> for _ <- 1..50 do
      ...>   sleep(2) # — every 2 ms in 100 ms.
      ...>   info(am, :key)[:max_processes]
      ...> end
      ...> |> Enum.max()
      42
      iex> fetch(am, :key, !: false)
      :error
  """
  @spec max_processes(am, key, pos_integer | :infinity) :: am
  def max_processes(agentmap, key, value)
      when (is_integer(value) and value > 0) or value == :infinity do
    req = %Req{action: :max_processes, key: key, data: value, timeout: :infinity}
    _cast(agentmap, req, [])
  end

  @doc """
  Returns information about the `key` — number of processes or maximum processes
  allowed.

  See `info/2`.
  """
  @spec info(agentmap, key, :processes) :: {:processes, pos_integer}
  @spec info(agentmap, key, :max_processes) :: {:max_processes, pos_integer | :infinity}
  def info(agentmap, key, :processes) do
    p = _call(agentmap, %Req{action: :processes, key: key})
    {:processes, p}
  end

  def info(agentmap, key, :max_processes) do
    max_p = _call(agentmap, %Req{action: :max_processes, key: key})
    {:max_processes, max_p}
  end

  @doc """
  Returns keyword with number of processes and maximum number of processes
  allowed for key.

  ## Examples

      iex> import :timer
      iex> import AgentMap
      iex> #
      ...> am = AgentMap.new()
      iex> #
      ...> info(am, :key)
      [processes: 0, max_processes: 5]
      #
      iex> max_processes(am, 3)
      5
      iex> info(am, :key)
      [processes: 0, max_processes: 3]
      #
      iex> am
      ...> |> cast(:key, fn _ -> sleep(10) end)
      ...> |> info(:key)
      [processes: 1, max_processes: 3]
      #
      iex> max_processes(am, 5)
      3
      iex> info(am, :key)[:max_processes]
      5
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

      iex> import :timer
      iex> import AgentMap
      iex> #
      iex> am = AgentMap.new()
      iex> for _ <- 1..100 do
      ...>   Task.async(fn ->
      ...>     get(am, :key, fn _ -> sleep(50) end, !: true)
      ...>   end)
      ...> end
      iex> sleep(10)
      iex> info(am, :key)[:processes]
      100
  """
  @spec info(agentmap, key) :: [
          processes: pos_integer,
          max_processes: pos_integer | :infinity
        ]
  def info(agentmap, key) do
    [
      info(agentmap, key, :processes),
      info(agentmap, key, :max_processes)
    ]
  end

  @doc """
  Fetches the value for a specific `key` from `agentmap`.

  If `agentmap` contains the given `key`, `{:ok, value}` is returned. If it
  doesn’t contain `key`, `:error` is returned.

  Returns value *immediately*, unless `!: false` option is given.

  ## Options

    * `!: false` — (`boolean`, `true`) to put this call in the
      [queue](#module-priority-calls-true);

    * `:timeout` — (`timeout`, `5000`). Is ignored if `cast: true` option is
      provided.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.fetch(am, :a)
      {:ok, 1}
      iex> AgentMap.fetch(am, :b)
      :error

      iex> am = AgentMap.new()
      iex> AgentMap.cast(am, :b, fn _ ->
      ...>   :timer.sleep(20); 42
      ...> end)
      iex> AgentMap.fetch(am, :b)
      :error
      iex> AgentMap.fetch(am, :b, !: false)
      {:ok, 42}
  """
  @spec fetch(agentmap, key, !: boolean, timeout: timeout) :: {:ok, value} | :error
  def fetch(agentmap, key, opts \\ [!: true, timeout: 5000]) do
    if match?({_, _}, opts[:timeout]) do
      raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable here."
    end

    if Keyword.get(opts, :!, true) do
      req = %Req{action: :fetch, key: key}
      _call(agentmap, req, opts)
    else
      fun = fn value ->
        if Process.get(:value) do
          {:ok, value}
        else
          :error
        end
      end

      get(agentmap, key, fun, opts)
    end
  end

  @doc """
  Fetches the value for a specific `key` from `agentmap`, erroring out if
  `agentmap` doesn't contain `key`.

  If `agentmap` contains the given `key`, the corresponding value is returned.
  If `agentmap` doesn't contain `key`, a `KeyError` exception is raised.

  Returns the current value, unless `!: false` option is given.

  ## Options

    * `!: false` — (`boolean`, `true`) to put this call in the
      [queue](#module-priority-calls-true);

    * `:timeout` — (`timeout`, `5000`). Is ignored if `cast: true` option is
      provided.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.fetch!(am, :a)
      1
      iex> AgentMap.fetch!(am, :b)
      ** (KeyError) key :b not found
  """
  @spec fetch!(agentmap, key, !: boolean, timeout: timeout) :: value | no_return
  def fetch!(agentmap, key, opts \\ [!: true, timeout: 5000]) do
    case fetch(agentmap, key, opts) do
      {:ok, value} ->
        value

      :error ->
        raise KeyError, key: key
    end
  end

  @doc """
  Returns whether the given `key` exists in the given `agentmap`.

  Syntactic sugar for

      match?({:ok, _}, fetch(agentmap, key, opts))

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.has_key?(am, :a)
      true
      iex> AgentMap.has_key?(am, :b)
      false
  """
  @spec has_key?(agentmap, key, !: boolean, timeout: timeout) :: boolean
  def has_key?(agentmap, key, opts \\ [!: true, timeout: 5000]) do
    match?({:ok, _}, fetch(agentmap, key, opts))
  end

  @doc """
  Removes and returns the value associated with `key` from `agentmap`.

  If there is no such `key` in `agentmap`, `default` is returned (`nil`).

  ## Options

    * `!: false` — (`boolean`, `true`) to make
    [non-priority](#module-priority-calls-true) put calls;

    * `timeout: {:drop, pos_integer}` — drops this call from queue when
    [timeout](#module-timeout) happen;

    * `:timeout` — (`timeout`, `5000`).

  ## Examples

      iex> am = AgentMap.new(a: 42, b: nil)
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
  @spec pop(agentmap, key, any, keyword) :: value | any
  def pop(agentmap, key, default \\ nil, opts \\ [!: true, timeout: 5000]) do
    if match?({:break, _}, opts[:timeout]) do
      raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable here."
    end

    opts = Keyword.put_new(opts, :!, true)

    fun = fn _ ->
      if Process.get(:value) do
        :pop
      end || {default}
    end

    get_and_update(agentmap, key, fun, opts)
  end

  @doc """
  Puts the given `value` under the `key` into the `agentmap`.

  By default, returns *immediately*, without waiting for actual put happen.

  ## Options

    * `!: false` — (`boolean`, `true`) to make
    [non-priority](#module-priority-calls-true) put calls;

    * `cast: false` — (`boolean`, `true`) to wait until actual put happend;

    * `timeout: {:drop, pos_integer}` — drops this call from queue when
    [timeout](#module-timeout) happen;

    * `:timeout` — (`timeout`, `5000`). Is ignored if `cast: true` is used.

  ## Examples

      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> AgentMap.put(:b, 2)
      ...> |> AgentMap.take([:a, :b])
      %{a: 1, b: 2}
  """
  @spec put(am, key, value, keyword) :: am
  def put(agentmap, key, value, opts \\ [!: true, cast: true]) do
    if match?({:break, _}, opts[:timeout]) do
      raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable here."
    end

    opts = Keyword.put_new(opts, :!, true)
    req = %Req{action: :put, key: key, data: value}

    if Keyword.get(opts, :cast, true) do
      # by default:
      _cast(agentmap, req, opts)
    else
      _call(agentmap, req, opts)
      agentmap
    end
  end

  @doc """
  Returns a snapshot with a key-value pairs taken from `agentmap`.

  Keys that are not in `agentmap` are ignored.

  Syntactic sugar for

      Multi.get(agentmap, keys, fn _ -> Process.get(:map) end, opts)

  ## Options

    * `!: false` — (`boolean`, `true`) to wait for execution of all the
    callbacks for all the `keys` at the moment of call. See [corresponding
    section](#module-priority-calls-true);

    * `:timeout` — (`timeout`, `5000`).

  ## Examples

      iex> import :timer
      iex> am = AgentMap.new(a: 1, b: 2, c: 3)
      iex> AgentMap.take(am, [:a, :b, :d])
      %{a: 1, b: 2}
      iex> #
      ...> am
      iex> |> AgentMap.cast(:a, &(sleep(10) && &1 + 1))
      iex> |> AgentMap.cast(:d, fn _ -> sleep(20); 42 end)
      ...> |> AgentMap.take([:a, :b, :d])
      %{a: 1, b: 2}
      iex> AgentMap.take(am, [:a, :b, :d], !: false)
      %{a: 2, b: 2, d: 42}
  """
  @spec take(agentmap, Enumerable.t(), keyword) :: map
  def take(agentmap, keys, opts \\ [!: true])

  def take(agentmap, keys, opts) when is_list(opts) do
    if match?({_, _}, opts[:timeout]) do
      raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable here."
    end

    opts = Keyword.put_new(opts, :!, true)
    fun = fn _ -> Process.get(:map) end

    Multi.get(agentmap, keys, fun, opts)
  end

  def take(agentmap, keys, t) do
    take(agentmap, keys, timeout: t)
  end

  @doc """
  Deletes the entry in the `agentmap` for a specific `key`.

  By default, returns *immediately*, without waiting for actual delete happens.

  ## Options

    * `cast: false` — (`boolean`, `true`) to wait for actual removal happen;

    * `!: true` — (`boolean`, `false`) to make
      [priority](#module-priority-calls-true) delete calls;
    * `timeout: {:drop, pos_integer}` — to drop this call from queue when
      [timeout](#module-timeout) happens;

    * `:timeout` — (`timeout`, `5000`). Is ignored if `cast: true` is given.

  ## Examples

      iex> %{a: 1, b: 2}
      ...> |> AgentMap.new()
      ...> |> AgentMap.delete(:a)
      ...> |> AgentMap.take([:a, :b])
      %{b: 2}
  """
  @spec delete(agentmap, key, keyword) :: agentmap
  def delete(agentmap, key, opts \\ [cast: true, !: false]) do
    if match?({:break, _}, opts[:timeout]) do
      raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable here."
    end

    req = %Req{action: :delete, key: key}

    if Keyword.get(opts, :cast, true) do
      # by default:
      _cast(agentmap, req, opts)
    else
      _call(agentmap, req, opts)
      agentmap
    end
  end

  @doc """
  Drops `keys` from `agentmap`.

  Be aware, that

      drop(agentmap, keys, cast: false)
      drop(agentmap, keys)

  is just a syntactic sugar for

      Multi.update(agentmap, keys, fn _ -> :drop end)
      Multi.cast(agentmap, keys, fn _ -> :drop end)

  By default, returns `agentmap` without waiting for actual drop happen.

  ## Options

    * `!: true` — (`boolean`, `false`) to make [priority
      calls](#module-priority-calls-true);

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`). Ignored if `cast: true`
      option is given;

    * `:cast` — (`boolean`, `true`) to wait for actual drop happens.

  ## Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.drop([:b, :d], cast: false)
      ...> |> AgentMap.keys()
      [:a, :c]
  """
  @spec drop(agentmap, Enumerable.t(), keyword) :: agentmap
  def drop(agentmap, keys, opts \\ [!: false, cast: true]) do
    if match?({:break, _}, opts[:timeout]) do
      raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable here."
    end

    fun = fn _ -> :drop end

    if Keyword.get(opts, :cast, true) do
      Multi.cast(agentmap, keys, fun, !: opts[:!])
    else
      Multi.update(agentmap, keys, fun, !: opts[:!])
    end
  end

  @doc """
  Returns all keys from `agentmap`.

  ## Examples

      iex> %{a: 1, b: nil, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.keys()
      [:a, :b, :c]
  """
  @spec keys(agentmap) :: [key]
  def keys(agentmap) do
    _call(agentmap, %Req{action: :keys}, !: true)
  end

  @doc """
  Returns all values from `agentmap`.

  ### Options

    * `!: false` — (`boolean`, `true`) to wait for execution of all callbacks in
    all the queues before return values. See [corresponding
    section](#module-priority-calls-true) for details.

    * `timeout` — (`timeout`, `5000`) can be [provided](#module-timeout) if `!:
      false` option is given.

  ### Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.values()
      [1, 2, 3]
  """
  @spec values(agentmap, !: boolean, timeout: timeout) :: [value]
  def values(agentmap, opts \\ [!: true]) do
    if match?({_, _}, opts[:timeout]) do
      raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable here."
    end

    fun = fn _ ->
      Map.values(Process.get(:map))
    end

    opts = Keyword.put_new(opts, :!, true)

    Multi.get(agentmap, keys(agentmap), fun, opts)
  end

  @doc """
  Increments value with given `key`.

  By default, returns *immediately*, not waiting for the actual increment
  happen.

  This call raises an `ArithmeticError` if the value is not numeric.

  ### Options

    * `:initial` — (`number`, `0`) if value does not exist it is considered to be
      the one given as initial;

    * `initial: false` — raises `KeyError` if value does not exist;

    * `:step` — (`number`, `1`) increment step;

    * `!: true` — (`boolean`, `false`) to make this call a
      [priority](#module-priority-calls-true);

    * `cast: false` — (`boolean`, `true`) to return only after decrement happend;

    * `timeout: {:drop, pos_integer}` — to drop this call from queue after given
      number of milliseconds;

    * `:timeout` — (`timeout`, `5000`). Is ignored if `cast: true` is given.

  ### Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> am
      iex> |> inc(:a)
      iex> |> fetch(:a, !: false)
      {:ok, 2}
      iex> am
      iex> |> dec(:b)
      iex> |> fetch(:b, !: false)
      {:ok, 1}
  """
  @spec inc(agentmap, key, keyword) :: agentmap
  def inc(agentmap, key, opts \\ [step: 1, cast: true, !: false, initial: 0]) do
    if match?({:break, _}, opts[:timeout]) do
      raise "Option `timeout: #{inspect(opts[:timeout])}` is not applicable here."
    end

    step = opts[:step] || 1
    initial = Keyword.get(opts, :initial, 0)

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

    req = %Req{action: :get_and_update, key: key, fun: fun}

    if Keyword.get(opts, :cast, true) do
      # by default:
      _cast(agentmap, req, opts)
    else
      _call(agentmap, req, opts)
      agentmap
    end
  end

  @doc """
  Decrements value with given `key`.

  Syntactic sugar for

      inc(agentmap, key, Keyword.update(opts, :step, -1, &(-&1)))

  See `inc/3` for details.
  """
  @spec dec(agentmap, key, keyword) :: agentmap
  def dec(agentmap, key, opts \\ [step: 1, cast: true, !: false, initial: 0]) do
    opts = Keyword.update(opts, :step, -1, &(-&1))
    inc(agentmap, key, opts)
  end

  @doc """
  Synchronously stops the `agentmap` with the given `reason`.

  It returns `:ok` if the `agentmap` terminates with the given reason. If the
  agentmap terminates with another reason, the call will exit.

  This function keeps OTP semantics regarding error reporting. If the reason is
  any other than `:normal`, `:shutdown` or `{:shutdown, _}`, an error report
  will be logged.

  ### Examples

      iex> {:ok, pid} = AgentMap.start_link()
      iex> AgentMap.stop(pid)
      :ok
  """
  @spec stop(agentmap, reason :: term, timeout) :: :ok
  def stop(agentmap, reason \\ :normal, timeout \\ :infinity) do
    agentmap
    |> pid()
    |> GenServer.stop(reason, timeout)
  end
end

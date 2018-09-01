defmodule AgentMap do
  @behaviour Access

  @enforce_keys [:link]
  defstruct @enforce_keys

  alias AgentMap.{Server, Req, IncError, Transaction}

  import Req, only: [timeout: 1]

  @moduledoc """
  The `AgentMap` can be seen as a stateful `Map` that parallelize operations
  made on different keys. Basically, it can be used as a cache, memoization,
  computational framework and, sometimes, as a `GenServer` replacement.

  Underneath it's a `GenServer` that holds a `Map`. When an `update/4`,
  `update!/4`, `get_and_update/4` or `cast/4` is called, a special temporary
  process called "worker" is spawned for the key passed as an argument. All
  subsequent calls will be forwarded to the message queue of this worker. This
  process respects the order of incoming new calls, executing them in a
  sequence, except for the `get/4` calls, which are processed as a parallel
  `Task`s. For each key, the degree of parallelization can be tweaked using the
  `max_processes/3` function. A worker will commit suicide after `10` ms of
  inactivity.

  `AgentMap` supports transactions — operations on a group of keys. See
  `AgentMap.Transaction`.

  ## Examples

  Create and use it as an ordinary `Map`:

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> am.a
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
  `Enumerable` protocol and to take benefit from the `Access` behaviour.

  Also, `AgentMap` can be started in an `Agent` manner:

      iex> {:ok, pid} = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.put(:a, 1)
      ...> |> AgentMap.get(:a)
      1
      iex> am = AgentMap.new(pid)
      iex> am.a
      1

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

  Also, take a look at the `test/memo.ex`.

  `AgentMap` provides possibility to make transactions (operations on multiple
  keys). Let's see an accounting demo:

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
          # Transaction call.
          AgentMap.get_and_update(__MODULE__, fn
            [nil, _] -> {:error}

            [_, nil] -> {:error}

            [b1, b2] when b1 >= amount ->
              {:ok, [b1 - amount, b2 + amount]}

            _ -> {:error}
          end, [from, to])
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

  ## `Enumerable` protocol and `Access` behaviour

  `%AgentMap{}` is a special struct that holds the pid of an `agentmap` process.
  `Enumerable` protocol is implemented for `%AgentMap{}`, so `Enum` should work
  as expected:

      iex> %{answer: 42}
      ...> |> AgentMap.new()
      ...> |> Enum.empty?()
      false

  Similary, `AgentMap` follows the `Access` behaviour:

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> am.a
      42

  (!) currently `put_in` operator does not work properly.

  ## Options

  ### Priority calls (`!: true`)

  Most of the functions support `!: true` option to make out-of-turn
  ("priority") calls.

  By default, on each key, no more than fifth `get/4` calls can be executed
  simultaneously. If `update!/4`, `update/4`, `cast/4`, `get_and_update/4` or a
  `6`-th `get/4` call came, a special worker process will be spawned that became
  the holder of the execution queue. It's the FIFO queue, but [selective
  receive](http://learnyousomeerlang.com/more-on-multiprocessing) is used to
  provide the possibility for some callbacks to be executed in the order of
  preference (out of turn).

  For example:

      iex> import AgentMap
      iex> import :timer
      iex> am = AgentMap.new(state: :ready)
      iex> am
      ...> |> cast(:state, fn _ -> sleep(50); :steady end)
      ...> |> cast(:state, fn _ -> sleep(50); :stop end)
      ...> |> cast(:state, fn _ -> sleep(50); :go! end, !: true)
      :ok
      iex> fetch(am, :state)
      {:ok, :ready}
      # — current state.
      # Right now :steady is executed.
      #
      iex> queue_len(am, :state)
      2
      # [:go!, :stop]
      iex> queue_len(am, :state, !: true)
      1
      # [:go!]
      iex> [get(am, :state),
      ...>  get(am, :state, !: true),
      ...>  get(am, :state, & &1, !: true),
      ...>  am.state]
      [:ready, :ready, :ready, :ready]
      # As the fetch/2, returns current state immediatelly.
      #
      iex> get(am, :state, !: false)
      :steady
      # Now executes: :go!, queue: [:stop],
      # because `!: true` are out of turn.
      #
      iex> get(am, :state, !: false)
      :go!
      # Now executes: :stop, queue: [].
      iex> get(am, :state, !: false)
      :stop

  Keep in mind that selective receive can lead to performance issues if the
  message queue becomes too fat. So it was decided to disable selective receive
  each time message queue of the worker process has more that `100` items. It
  will be turned on again when message queue became empty.

  ### Timeout

  Timeout is an integer greater than zero which specifies how many milliseconds
  are allowed before the `agentmap` executes the `fun` and returns a result, or
  an atom `:infinity` to wait indefinitely. If no result is received within the
  specified time, the caller exits. By default it is set to the `5000 ms` = `5
  sec`.

  For example:

      get_and_update(agentmap, :key, fun)
      get_and_update(agentmap, :key, fun, 5000)
      get_and_update(agentmap, :key, fun, timeout: 5000)
      get_and_update(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.

  If no result is received within the specified time, the caller exits, (!) but
  the callback will remain in a queue!

      iex> import AgentMap
      iex> import :timer
      iex> Process.flag(:trap_exit, true)
      iex> am =
      ...>   AgentMap.new(key: 42)
      iex> am
      ...> |> cast(:key, fn v -> sleep(50); v - 9 end)
      ...> |> put(:key, 24, timeout: 10)
      iex> Process.info(self())[:message_queue_len]
      1
      # — 10 ms later, there was a timeout.
      #
      iex> get(am, :key)
      42
      # — cast call is still executed.
      iex> get(am, :key, !: false)
      24
      # — after 40 ms, cast/4 and put/4 calls are executed.

  — to change this behaviour, provide `{:drop, timeout}` value. For instance, in
  this call:

      iex> import AgentMap
      iex> import :timer
      iex> Process.flag(:trap_exit, true)
      iex> am =
      ...>   AgentMap.new(key: 42)
      iex> am
      ...> |> cast(:key, fn v -> sleep(50); v - 9 end)
      ...> |> put(:key, 24, timeout: {:drop, 10})
      ...> |> get(:key, !: false)
      33
      iex> Process.info(self())[:message_queue_len]
      1

  `put/4` was never executed because it was dropped from queue, although,
  `GenServer` exit signal will be send.

  If timeout happen while callback is executed — it will not be interrupted. For
  this case special `{:break, pos_integer}` option exist that instructs
  `AgentMap` to wrap call in a `Task`:

      import :timer
      AgentMap.cast(
        agentmap,
        :key,
        fn _ -> sleep(:infinity) end,
        timeout: {:break, 6000}
      )

  In this particular case the `fn _ -> sleep(:infinity) end` callback is wrapped
  in a `Task` which has `6` sec before shutdown.

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

  @typedoc "Return values for the `start*` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid} | term}

  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "`AgentMap` server (name, link, pid, …)"
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

  defp pid(%__MODULE__{link: am}), do: am
  defp pid(am), do: am

  @doc """
  Wraps the `fun` in the `try…catch` before applying `args`.

  Returns `{:ok, reply}`, `{:error, :badfun}` or `{:error, :badarity}`.

  ## Examples

      iex> AgentMap.safe_apply(fn -> 1 end, [:extra_arg])
      {:error, :badarity}
      iex> AgentMap.safe_apply(:notfun, [])
      {:error, :badfun}
      iex> AgentMap.safe_apply(raise KeyError, [])
      {:error, %KeyError{}}
      iex> AgentMap.safe_apply(fn -> 1 end, [])
      1
  """
  def safe_apply(fun, args) do
    Server.safe_apply(fun, args)
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
  **struct** that contains pid of the `AgentMap`.

  As the argument, keyword with states can be provided or the pid of an already
  started agentmap.

  ## Examples

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> am.a
      42
      iex> AgentMap.keys(am)
      [:a, :b]

      iex> {:ok, pid} = AgentMap.start_link()
      iex> am = pid
      ...> |> AgentMap.new()
      ...> |> AgentMap.put(:a, 1)
      iex> am.a
      1
  """
  @spec new(Enumerable.t() | am) :: am
  def new(enumerable)

  def new(%__MODULE__{} = am), do: am
  def new(%_{} = struct), do: new(Map.new(struct))
  def new(keyword) when is_list(keyword), do: new(Map.new(keyword))

  def new(%{} = m) when is_map(m) do
    funs =
      for {key, value} <- m do
        {key, fn -> value end}
      end

    {:ok, am} = start_link(funs)
    new(am)
  end

  def new(am), do: %__MODULE__{link: GenServer.whereis(am)}

  @doc """
  Creates agentmap from an `enumerable` via the given transformation function.

  Duplicated keys are removed; the latest one prevails.

  ## Examples

      iex> am = AgentMap.new([:a, :b], fn x -> {x, x} end)
      iex> AgentMap.take(am, [:a, :b])
      %{a: :a, b: :b}
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
  the end, `GenServer.options`. For each key, fun is executed in a separate
  `Task`.

  ## Options

    * `:name` — (any) if present, is used for registration as described in the
    module documentation;

    * `:debug` — if present, the corresponding function in the [`:sys`
    module](http://www.erlang.org/doc/man/sys.html) will be invoked;

    * `:spawn_opt` — if present, its value will be passed as options to the
    underlying process as in `Process.spawn/4`;

    * `:timeout` — (pos_integer | :infinity, 5000) the agentmap is allowed to
    spend at most the given number of milliseconds on the whole process of
    initialization or it will be terminated and the start function will return
    `{:error, :timeout}`.

  ## Return values

  If the server is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a server with the
  specified name already exists, the function returns `{:error,
  {:already_started, pid}}` with the PID of that process.

  If one of the callbacks fails, the function returns `{:error, [{key,
  error_reason}]}`, where `error_reason` is `:timeout`, `:badfun`, `:badarity`,
  `{:exit, reason}` or an arbitrary exception. For example:

      iex> {:ok, pid} =
      ...>   AgentMap.start_link(f: fn ->
      ...>     Calc.fib(4)
      ...>   end, timeout: 5000)
      iex> AgentMap.get(pid, :f)
      3

  — starts server with a predefined single key `:f`.

  But if one provide actual value instead of zero-arity fun, `{:error, :badfun}`
  will be returned. If the number of arguments differs from the fun arity —
  `{:error, :badarity}` will be returned:

      iex> AgentMap.start(f: 3)
      {:error, f: :badfun}
      iex> AgentMap.start(f: & &1)
      {:error, f: :badarity}
      iex> {:error, f: {exception, _stacktrace}} =
      ...>   AgentMap.start(f: fn -> raise "oops" end)
      iex> exception
      %RuntimeError{message: "oops"}

  ## Examples

      iex> {:ok, pid} =
      ...>   AgentMap.start_link(key: fn -> 42 end)
      iex> AgentMap.get(pid, :key, & &1)
      42
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
      iex> AgentMap.start(a: 42,
      ...>                b: fn -> sleep(150) end,
      ...>                c: fn -> sleep(:infinity) end,
      ...>                timeout: 100)
      {:error, a: :badfun, b: :timeout, c: :timeout}
      iex> err = AgentMap.start(a: 76,
      ...>                      b: fn -> raise "oops" end)
      iex> {:error, a: :badfun, b: {exception, _stacktrace}} = err
      iex> exception
      %RuntimeError{message: "oops"}
  """
  @spec start([{key, (() -> any)} | GenServer.option()]) :: on_start
  def start(funs_and_opts \\ [timeout: 5000]) do
    {args, opts} = prepair(funs_and_opts)
    GenServer.start(Server, args, opts)
  end

  @doc false
  def _call(agentmap, req, opts) do
    t = timeout(opts[:timeout]) || 5000
    GenServer.call(pid(agentmap), struct(req, opts), t)
  end

  defp _cast(agentmap, %Req{} = req, opts) do
    GenServer.cast(pid(agentmap), struct(req, opts))
    agentmap
  end

  defp _call_or_cast(agentmap, %Req{} = req, opts) do
    if Keyword.get(opts, :cast, true) do
      # by default:
      _cast(agentmap, req, opts)
    else
      _call(agentmap, req, opts)
    end
  end

  ##
  ## GET
  ##

  @doc """
  Gets an `agentmap` value via the given `fun`.

  The function `fun` is sent to the `agentmap` which invokes callback, passing
  the value associated with `key` (or `nil`). The result of the invocation is
  returned from this function. This call does not change value, so a series of
  `get`-calls can and will be executed as a parallel `Task`s (see
  `max_processes/3`).

  If there are callbacks awaiting invocation, this call will be added to the end
  of the corresponding queue. If `!: true` option is given, `fun` will be
  executed immediately, passing current value as an argument.

  Special syntax sugar `get(agentmap, fun, key, opts)` is supported for
  the `AgentMap.Transaction.get/4`.

  ## Options

    * `!: true` — (`boolean`, `false`) to make [priority
      calls](#module-priority-calls-true). `key` could have an associated queue
      of callbacks awaiting of execution, "priority" version allows to execute
      given `fun` immediately in a separate `Task`, providing the current value
      as an argument. This calls are not counted in a number of processes
      allowed to run in parallel (see `max_processes/3`).

      To achieve the same affect, but on the client side, use the following:

          case AgentMap.fetch(agentmap, key) do
            {:ok, value} ->
              fun.(value)

            :error ->
              fun.(nil)
          end

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `timeout: {:break, pos_integer}` — to throw out from queue or cancel a
      running call upon the occurence of a timeout. See [timeout
      section](#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`).

  ## Examples

      iex> import AgentMap
      iex> am = AgentMap.new()
      iex> get(am, :Alice, & &1)
      nil
      iex> put(am, :Alice, 42)
      iex> get(am, :Alice, & &1+1)
      43

   "Priority" calls:

      iex> import AgentMap
      iex> am = AgentMap.new(key: 42)
      iex> cast(am, :key, fn _ -> :timer.sleep(100); 43 end)
      iex> get(am, :key, & &1, !: true)
      42
      iex> am.key # the same
      42
      iex> get(am, :key, & &1)
      43
      iex> get(am, :key, & &1, !: true)
      43

  ## Special process dictionary keys

  One can use `:"$key"` and `:"$value"` dictionary keys:

      iex> import AgentMap
      iex> am = AgentMap.new(a: nil)
      iex> get(am, :a, fn _ -> Process.get(:"$key") end)
      :a
      iex> get(am, :a, fn nil -> Process.get(:"$value") end)
      {:value, nil}
      iex> get(am, :b, fn nil -> Process.get(:"$value") end)
      nil
  """
  @spec get(am, ([value] -> get), [key], keyword) :: get when get: var
  @spec get(am, key, (value -> get), keyword) :: get when get: var

  # 4
  def get(agentmap, key, fun, opts)
  def get(agentmap, fun, keys, opts)

  def get(agentmap, fun, keys, opts) when is_function(fun, 1) and is_list(keys) do
    Transaction.get(agentmap, keys, fun, opts)
  end

  def get(agentmap, key, fun, opts) when is_function(fun, 1) do
    req = %Req{action: :get, data: {key, fun}}
    _call(agentmap, req, opts)
  end

  # 3
  def get(agentmap, key, default)

  def get(agentmap, fun, keys) when is_function(fun, 1) and is_list(keys) do
    req = %Req{action: :get, data: {fun, keys}}
    _call(agentmap, req, [])
  end

  def get(agentmap, key, fun) when is_function(fun, 1) do
    req = %Req{action: :get, data: {key, fun}}
    _call(agentmap, req, [])
  end

  #

  @spec get(am, key, d) :: value | d when d: var
  @spec get(am, key) :: value | nil

  def get(agentmap, key, default)

  def get(agentmap, key, default) do
    case fetch(agentmap, key) do
      {:ok, value} -> value
      :error -> default
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
      if Process.get(:"$value") do
        value
      else
        fun.()
      end
    end

    get(agentmap, key, cb)
  end

  @doc """
  Immediately returns the value for a specific `key` in `agentmap`.

  This function supports `default` argument:

      iex> am = AgentMap.new(a: 42)
      iex> AgentMap.get(am, :a)
      42
      iex> AgentMap.get(am, :b)
      nil
      iex> AgentMap.get(am, :b, :error)
      :error

  See `Access.get/3`.
  """
  def get(agentmap, key), do: get(agentmap, key, nil)

  ##
  ## GET_AND_UPDATE
  ##

  @doc """
  Gets the value for `key` in `agentmap` and updates it, all in one pass.

  The function `fun` is sent to the `agentmap` which invokes callback passing
  the value associated with `key` (or `nil`). The result of the invocation is
  returned from this function.

  For ex.:

      get_and_update(account, :Alice, & {&1, &1 + 1_000_000})

  returns the balance of Alice before the deposit of a million dollars was made.

  A `fun` can return:

    * a two element tuple: `{"get" value, new value}`;
    * a one element tuple `{"get" value}` — the value is not changed;
    * `:pop` — similar to `Map.get_and_update/3` this returns value with given
      `key` and removes it from `agentmap`;
    * `:id` to return a current value, while not changing it.

  Special syntax sugar `get_and_update(agentmap, fun, key, opts)` is supported
  for the `AgentMap.Transaction.get_and_update/4`.

  ## Options

    * `!: true` — (`boolean`, `false`) to make [priority
      calls](#module-priority-calls-true). `key` could have an associated queue
      of callbacks, awaiting of execution. If such queue exists, asks worker via
      "selective receive" to process this callback in prioriry order;

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `timeout: {:break, pos_integer}` — to throw out from queue or cancel a
      running call upon the occurence of a timeout. See [timeout
      section](#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`).

  ## Examples

      iex> import AgentMap
      iex> am = new(uno: 22)
      iex> get_and_update(am, :uno, & {&1, &1 + 1})
      22
      iex> get(am, :uno)
      23
      iex> get_and_update(am, :uno, fn _ -> :pop end)
      23
      iex> has_key?(am, :uno)
      false
      iex> get_and_update(am, :uno, fn _ -> :id end)
      nil
      iex> has_key?(am, :uno)
      false
      iex> get_and_update(am, :uno, fn v -> {v,v} end)
      nil
      iex> has_key?(am, :uno)
      true
  """
  # 4
  @typedoc """
  Callback that is used for a single-key call.
  """
  @type cb(get) ::
          (value ->
             {get}
             | {get, value}
             | :pop
             | :id)

  @typedoc """
  Callback that is used for a transactional call.
  """
  @type cb_t(get) ::
          ([value] ->
             {get}
             | {get, [value] | :drop | :id}
             | [{any} | {any, value} | :pop | :id]
             | :pop
             | :id)

  @spec get_and_update(am, key, cb(get), keyword) :: get | value
        when get: var
  @spec get_and_update(am, cb_t(get), [key], keyword) :: get | [value]
        when get: var
  def get_and_update(agentmap, key, fun, opts \\ [!: false, timeout: 5000])

  def get_and_update(agentmap, fun, keys, opts) when is_function(fun, 1) and is_list(keys) do
    Transaction.get_and_update(agentmap, keys, fun, opts)
  end

  def get_and_update(agentmap, key, fun, opts) when is_function(fun, 1) do
    req = %Req{action: :get_and_update, data: {key, fun}}
    _call(agentmap, req, opts)
  end

  ##
  ## UPDATE
  ##

  @doc """
  Updates the `key` in `agentmap` with the given `fun`.

  This function always returns the same `agentmap` to make piping work.

  This call is no more than a syntax sugar for `get_and_update(am, key, &{am,
  fun.(&1)}, opts)`.

  Special syntax sugar `update(agentmap, fun, key, opts)` is supported for the
  `AgentMap.Transaction.update/4`.

  ## Options

  The same as for `get_and_update/4`.

  ## Examples

      update(account, :Alice, & &1 + 1_000_000)

  returns the balance of Alice before the deposit of a million dollars was made.

      iex> {:ok, pid} = AgentMap.start_link(key: fn -> 42 end)
      iex> pid
      ...> |> AgentMap.update(:key, & &1+1)
      ...> |> AgentMap.get(:key, & &1)
      43
      #
      iex> pid
      ...> |> AgentMap.update(:otherkey, fn nil -> 42 end)
      ...> |> AgentMap.get(:otherkey, & &1)
      42
  """
  # 4
  @spec update(am, key, (value -> value), keyword) :: am
  @spec update(am, ([value] -> [value] | :drop | :id), [key], keyword) :: am
  def update(agentmap, key, fun, opts \\ [!: false, timeout: 5000])

  def update(agentmap, fun, keys, opts) when is_function(fun, 1) do
    Transaction.update(agentmap, keys, fun, opts)
  end

  def update(agentmap, key, fun, opts) when is_function(fun, 1) do
    get_and_update(agentmap, key, &{agentmap, fun.(&1)}, opts)
  end

  def update(agentmap, key, initial, fun) when is_function(fun, 1) do
    update(agentmap, key, initial, fun, [])
  end

  @doc """
  For compatibility with `Map` API, `update(agentmap, key, initial, fun)` call
  is supported.

      iex> AgentMap.new(a: 42)
      ...> |> AgentMap.update(:a, :value, & &1 + 1)
      ...> |> AgentMap.update(:b, :value, & &1 + 1)
      ...> |> AgentMap.take([:a,:b])
      %{a: 43, b: :value}
  """
  # 5
  @spec update(am, key, any, (value -> value), [{:!, boolean} | {:timeout, timeout}]) :: am
  def update(agentmap, key, initial, fun, opts) when is_function(fun, 1) do
    cb = fn value ->
      if Process.get(:"$value") do
        apply(fun, [value])
      else
        initial
      end
    end

    update(agentmap, key, cb, opts)
  end

  @doc """
  Updates `key` with the given function.

  If `key` is present in `agentmap`, `fun` is invoked with value as argument and
  its result is used as the new value of `key`. If `key` is not present in
  `agentmap`, a `KeyError` exception is raised.

  ## Options

  The same as for `get_and_update/4`.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> am
      ...> |> AgentMap.update!(:a, &(&1 * 2))
      ...> |> AgentMap.get(:a)
      2
      iex> AgentMap.update!(am, :b, &(&1 * 2))
      ** (KeyError) key :b not found
      iex> import :timer
      iex> am
      ...> |> AgentMap.cast(:a, sleep(50))
      ...> |> AgentMap.cast(:a, sleep(100))
      ...> |> AgentMap.update!(:a, fn _ -> 42 end, !: true)
      ...> |> AgentMap.get(:a)
      42
      iex> AgentMap.get(am, :a, & &1)
      :ok
  """
  @spec update!(am, key, (value -> value), keyword) :: am
  def update!(agentmap, key, fun, opts \\ [!: false, timeout: 5000])
      when is_function(fun, 1) do
    cb = fn value ->
      if Process.get(:"$value") do
        {:ok, fun.(value)}
      else
        {:error}
      end
    end

    case get_and_update(agentmap, key, cb, opts) do
      :ok ->
        agentmap

      :error ->
        raise KeyError, key: key
    end
  end

  @doc """
  Alters the value stored under `key`, but only if `key` already exists in
  `agentmap`.

  If `key` is not present in `agentmap`, a `KeyError` exception is raised.

  ## Options

  The same as for `get_and_update/4`.

  ## Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> am
      ...> |> AgentMap.replace!(:a, 3, cast: false)
      ...> |> AgentMap.values()
      [3, 2]
      iex> AgentMap.replace!(am, :c, 2)
      ** (KeyError) key :c not found

      iex> am = AgentMap.new(a: 1)
      iex> import :timer
      iex> am
      ...> |> AgentMap.cast(:a, fn _ -> sleep(50); 2 end)
      ...> |> AgentMap.replace!(:a, 3)
      ...> |> AgentMap.cast(:a, fn _ -> sleep(50); 2 end)
      ...> |> AgentMap.cast(:a, fn _ -> sleep(100); 3 end)
      ...> |> AgentMap.replace!(:a, 42, !: true)
      ...> |> AgentMap.get(:a)
      42
      ...> AgentMap.get(am, :a, !: false)
      3
  """
  @spec replace!(agentmap, key, value, keyword) :: agentmap
  def replace!(agentmap, key, value, opts \\ [!: false, timeout: 5000]) do
    update!(agentmap, key, fn _ -> value end, opts)
  end

  ##
  ## CAST
  ##

  @doc """
  Performs `cast` ("fire and forget"). Works the same as `update/4`, but uses
  `GenServer.cast/2`.

  Immediately returns unchanged `agentmap` argument to support piping.

  The options are the same as for `get_and_update/4`, except for the `timeout:
  pos_integer`.

  Special syntax sugar `cast(agentmap, fun, key, opts)` is supported for the
  `AgentMap.Transaction.cast/4`.
  """
  @spec cast(am, key, (value -> value), keyword) :: am
  @spec cast(am, ([value] -> [value]), [key], keyword) :: am
  @spec cast(am, ([value] -> :drop | :id), [key], keyword) :: am
  def cast(agentmap, key, fun, opts \\ [!: false])

  def cast(agentmap, fun, keys, opts) when is_function(fun, 1) do
    Transaction.cast(agentmap, keys, fun, opts)
  end

  def cast(agentmap, key, fun, opts) when is_function(fun, 1) do
    req = %Req{action: :get_and_update, data: {key, &{:_, fun.(&1)}}}
    _cast(agentmap, req, opts)
  end

  @doc """
  Sets the default `:max_processes` value. Returns the old one.

  See `max_processes/3`.
  """
  @spec max_processes(agentmap, pos_integer | :infinity) :: pos_integer | :infinity
  def max_processes(agentmap, value)
      when (is_integer(value) or value == :infinity) and value > 0 do
    req = %Req{action: :max_processes, data: value, !: true}
    _call(agentmap, req, [])
  end

  @doc """
  Sets the `:max_processes` value for the given `key`.
  Returns the old value.

  `agentmap` can execute `get/4` calls on the same key concurrently.
  `max_processes` option specifies number of processes allowed per key (`-1`
  process for the worker process).

  Default value is `5`, but it can be changed via `max_processes/2`.

      iex> import :timer
      iex> am = AgentMap.new(key: 42)
      iex> for _ <- 1..4, do: spawn(fn ->
      ...>   AgentMap.get(am, :key, fn _ -> sleep(100) end)
      ...> end)
      iex> AgentMap.get(am, :key, fn _ -> sleep(100) end)
      :ok

  will be executed in around of `100` ms, not `500`. This sequence:

      import :timer
      AgentMap.new(key: 42)
      |> AgentMap.get(:key, fn _ -> sleep(100) end)
      |> AgentMap.cast(:key, fn _ -> sleep(100) end)
      |> AgentMap.cast(:key, fn _ -> sleep(100) end)

  will run for `200` ms as `agentmap` can parallelize any sequence of `get/3`
  calls ending with `get_and_update/3`, `update/3` or `cast/3`.

  Use `max_processes: 1` to execute `get` calls in sequence.

  ## Examples

      iex> am = AgentMap.new()
      iex> AgentMap.max_processes(am, :a, 42)
      5
      iex> AgentMap.max_processes(am, :a, :infinity)
      42
  """
  @spec max_processes(agentmap, key, pos_integer | :infinity) :: pos_integer | :infinity
  def max_processes(agentmap, key, value)
      when (is_integer(value) or value == :infinity) and value > 0 do
    req = %Req{action: :max_processes, data: {key, value}, !: true}
    _call(agentmap, req, [])
  end

  @doc """
  Fetches the value for a specific `key` from `agentmap`.

  If `agentmap` contains the given `key`, `{:ok, value}` is returned. If it
  doesn’t contain `key`, `:error` is returned.

  Returns value *immediately*, unless `!: false` option is given.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.fetch(am, :a)
      {:ok, 1}
      iex> AgentMap.fetch(am, :b)
      :error

  ## Options

    * `!: false` — (`boolean`, `true`) to put this call in the
    [queue](#module-priority-calls-true);

    * `:timeout` — (`timeout`, `5000`).

  ## Examples

      iex> import :timer
      iex> am = AgentMap.new()
      iex> AgentMap.cast(am, :b, fn _ ->
      ...>   sleep(50); 42
      ...> end)
      iex> AgentMap.fetch(am, :b)
      :error
      iex> AgentMap.fetch(am, :b, !: false)
      {:ok, 42}
  """
  @spec fetch(agentmap, key, !: boolean, timeout: 5000) :: {:ok, value} | :error
  def fetch(agentmap, key, opts \\ [!: true, timeout: 5000]) do
    if Keyword.get(opts, :!, true) do
      req = %Req{action: :fetch, data: key}
      _call(agentmap, req, opts)
    else
      get(agentmap, key, fn value ->
        if Process.get(:"$value") do
          {:ok, value}
        end || :error
      end)
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

    * `:timeout` — (`timeout`, `5000`).

  ## Examples

      iex> import :timer
      iex> am = AgentMap.new()
      iex> AgentMap.cast(am, :b, fn _ ->
      ...>   sleep(50); 42
      ...> end)
      iex> AgentMap.fetch!(am, :b)
      ** (KeyError) key :b not found
      iex> AgentMap.fetch!(am, :b, !: false)
      {:ok, 42}

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

  Syntax sugar for

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

  The same (but slowly) can be achieved with

      get_and_update(agentmap, key, fn _ ->
        case Process.get(:"$value") do
          :pop
        else
          {default}
        end
      end)

  ## Options

    * `!: false` — (`boolean`, `true`) to make
    [non-priority](#module-priority-calls-true) put calls;

    * `timeout: {:drop, pos_integer}` — drops this call from queue when
    [timeout](#module-timeout) happen;

    * `:timeout` — (`timeout`, `5000`).

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.pop(am, :a)
      1
      iex> AgentMap.pop(am, :a)
      nil
      iex> AgentMap.pop(am, :b)
      nil
      iex> AgentMap.pop(am, :b, :error)
      :error
      iex> Enum.empty?(am)
      true

  `nil` values are processed correctly:

      iex> am = AgentMap.new(a: nil, b: 1)
      iex> AgentMap.pop(am, :b)
      1
      iex> AgentMap.pop(am, :b, :no)
      :no
      iex> AgentMap.pop(am, :b)
      nil
      iex> AgentMap.pop(am, :a, :no)
      nil
      iex> AgentMap.pop(am, :a, :no)
      :no
  """
  @spec pop(agentmap, key, any, keyword) :: value | any
  def pop(agentmap, key, default \\ nil, opts \\ [!: true, timeout: 5000]) do
    opts = Keyword.put_new(opts, :!, true)

    fun = fn _ ->
      if Process.get(:"$value") do
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

    * `:timeout` — (`timeout`, `5000`) ignored if cast is used.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> am
      ...> |> AgentMap.put(:b, 2)
      ...> |> AgentMap.take([:a, :b])
      %{a: 1, b: 2}
      iex> am
      ...> |> AgentMap.put(:a, 3)
      ...> |> AgentMap.take([:a, :b])
      %{a: 3, b: 2}
  """
  @spec put(am, key, value, keyword) :: am
  def put(agentmap, key, value, opts \\ [!: true, cast: true]) do
    opts = Keyword.put_new(opts, :!, true)
    req = %Req{action: :put, data: {key, value}}
    _call_or_cast(agentmap, req, opts)

    agentmap
  end

  @doc """
  Returns a snapshot with a key-value pairs taken from `agentmap`.

  Keys that are not in `agentmap` are ignored.

  It is a syntax sugar for

      get(agentmap, fn _ -> Process.get(:"$map") end, keys)

  ## Options

    * `!: false` — (`boolean`, `true`) to wait for execution of all the callbacks
    for all the `keys` at the moment of call. See [corresponding
    section](#module-priority-calls-true);

    * `:timeout` — (`timeout`, `5000`).

  ## Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.take([:a, :c, :e])
      %{a: 1, c: 3}

      iex> import :timer
      iex> AgentMap.new(a: 1)
      ...> |> AgentMap.cast(:a, fn _ -> sleep(100); 42 end)
      ...> |> AgentMap.take([:a])
      %{a: 1}
      #
      # But:
      #
      iex> AgentMap.new(a: 1)
      ...> |> AgentMap.cast(fn _ -> sleep(100); 42 end)
      ...> |> AgentMap.take([:a], !: false)
      %{a: 42}
  """
  @spec take(agentmap, Enumerable.t(), keyword) :: map
  def take(agentmap, keys, opts \\ [!: true]) do
    opts = Keyword.put_new(opts, :!, true)
    fun = fn _ -> Process.get(:"$map") end
    get(agentmap, fun, keys, opts)
  end

  @doc """
  Deletes the entry in the `agentmap` for a specific `key`.

  By default, returns *immediately*, without waiting for actual delete happen.

  ## Options

    * `!: true` — (`boolean`, `false`) to make
    [priority](#module-priority-calls-true) delete calls;

    * `cast: false` — (`boolean`, `true`) to wait until actual drop happend;

    * `timeout: {:drop, pos_integer}` — drops this call from queue when
      [timeout](#module-timeout) happen;

    * `:timeout` — (`timeout`, `5000`) ignored if cast is used.

  ## Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> am
      ...> |> AgentMap.delete(:a)
      ...> |> AgentMap.take([:a, :b])
      %{b: 2}
      #
      iex> am
      ...> |> AgentMap.delete(:a)
      ...> |> AgentMap.take([:a, :b])
      %{b: 2}
  """
  @spec delete(agentmap, key, keyword) :: agentmap
  def delete(agentmap, key, opts \\ [!: false, cast: true]) do
    fun = fn _ -> :pop end
    req = %Req{action: :get_and_update, data: {key, fun}}
    _call_or_cast(agentmap, req, opts)
  end

  @doc """
  Drops `keys` from `agentmap`.

  Be aware, that

      drop(agentmap, keys, cast: false)
      drop(agentmap, keys)

  is just a syntax sugar for

      update(agentmap, fn _ -> :drop end, keys)
      cast(agentmap, fn _ -> :drop end, keys)

  By default, returns `agentmap` without waiting for actual drop happen.

  ## Options

    * `!: true` — (`boolean`, `false`) to make [priority
      calls](#module-priority-calls-true);

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`) if `cast: false` is
      given;

    * `:cast` — (`boolean`, `true`) wait for actual drop happen?

  ## Examples

      ...> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.drop([:b, :d])
      ...> |> AgentMap.keys()
      [:a, :c]
  """
  @spec drop(agentmap, Enumerable.t(), keyword) :: agentmap
  def drop(agentmap, keys, opts \\ [!: false, cast: true]) do
    fun = fn _ -> :drop end

    if Keyword.get(opts, :cast, true) do
      cast(agentmap, fun, keys, !: opts[:!])
    else
      update(agentmap, fun, keys, !: opts[:!])
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

    * `timeout` — (`timeout`, `5000`) can be [provided](#module-timeout).

  ### Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.values()
      [1, 2, 3]
  """
  @spec values(agentmap, !: boolean, timeout: timeout) :: [value]
  def values(agentmap, opts \\ [!: true]) do
    opts = Keyword.put_new(opts, :!, true)
    _call(agentmap, %Req{action: :values}, opts)
  end

  @doc """
  Returns the size of the execution queue for the given `key`.

  ### Options

    * `!: (false) true` — (`boolean`) to count only (not) [priority
      callbacks](#module-priority-calls-true) in the `key` queue.

  ### Examples

      iex> import :timer
      iex> am = AgentMap.new(a: 1, b: 2)
      iex> AgentMap.queue_len(am, :a)
      0
      iex> am
      ...> |> AgentMap.cast(:a, fn _ -> sleep(100) end)
      ...> |> AgentMap.cast(:a, fn _ -> sleep(100) end)
      ...> |> AgentMap.cast(:a, fn _ -> sleep(100) end, !: true)
      iex> :timer.sleep(10)
      iex> AgentMap.queue_len(am, :a)
      2
      iex> AgentMap.queue_len(am, :a, !: true)
      1
      iex> AgentMap.queue_len(am, :a, !: false)
      1
      iex> AgentMap.queue_len(am, :b)
      0
  """
  @spec queue_len(agentmap, key, [!: boolean] | []) :: non_neg_integer
  def queue_len(agentmap, key, opts \\ []) do
    opts = Keyword.take(opts, [:!])
    _call(agentmap, %Req{action: :queue_len, data: {key, opts}}, [])
  end

  @doc """
  Increments value with given `key`.

  By default, returns immediately, without waiting for the actual increment
  happen.

  This call raises an `ArithmeticError` if the value is not numeric.

  ### Options

    * `:initial` — (`number`, `0`) if value does not exist it is considered to be
      the one given as initial;

    * `initial: false` — raises `KeyError` if value does not exist;

    * `:step` — (`number`, `1`) increment step;

    * `!: true` — (`boolean`, `false`) makes this call a
      [priority](#module-priority-calls-true);

    * `cast: false` — (`boolean`, `true`) to return only after decrement happend;

    * `timeout: {:drop, pos_integer}` — drops this call from queue after given
      number of milliseconds;

    * `:timeout` — (`timeout`, `5000`) ignored if cast is used.

  ### Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> AgentMap.inc(am, :a)
      iex> AgentMap.get(am, :a)
      2
      iex> AgentMap.dec(am, :b)
      iex> AgentMap.get(am, :b)
      1
  """
  @spec inc(agentmap, key, keyword) :: agentmap
  def inc(agentmap, key, opts \\ [step: 1, cast: true, !: false, initial: 0]) do
    step = opts[:step] || 1
    initial = Keyword.get(opts, :initial, 0)

    fun = fn
      v when is_number(v) ->
        {:ok, v + step}

      v ->
        if Process.get(:"$value") do
          raise IncError, key: key, value: v, step: step
        else
          if initial do
            {:ok, initial + step}
          else
            raise KeyError, key: key
          end
        end
    end

    req = %Req{action: :get_and_update, data: {key, fun}}
    _call_or_cast(agentmap, req, opts)
    agentmap
  end

  @doc """
  Decrements value with given `key`.

  It is a syntax sugar for

      opts =
        Keyword.update(opts, :step, -1, & -&1)
      inc(agentmap, key, opts)

  See `inc/3` for details.
  """
  @spec dec(agentmap, key, keyword) :: agentmap
  def dec(agentmap, key, opts \\ [step: 1, cast: true, !: false, initial: 0, drop: :infinity]) do
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

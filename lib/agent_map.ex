defmodule AgentMap do
  @behaviour Access

  @enforce_keys [:link]
  defstruct @enforce_keys

  alias AgentMap.{Common, Server, Req, IncError}

  import Enum, only: [uniq: 1]

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

  `AgentMap` supports transactions — operations on a group of values (take a
  look at the [examples](#examples)).

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

  Also `AgentMap` can be started in an `Agent` manner:

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
  simultaneously. If update!/4`, `update/4`, `cast/4`, `get_and_update/4` or a
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
      ...> |> cast(:key, & sleep(50); &1-9)
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
      ...> |> cast(:key, & sleep(50); &1-9)
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

  In this case the `fn _ -> sleep(:infinity) end` callback is wrapped in a
  `Task` which has `6` sec before shutdown.

  ## Name registration

  An agentmap is bound to the same name registration rules as `GenServers`, see
  the `GenServer` documentation for details.

  ## Other

  Finally, note that `use AgentMap` defines a `child_spec/1` function, allowing
  the defined module to be put under a supervision tree. The generated
  `child_spec/1` can be customized with the following options:

    * `:id` - the child specification id, defauts to the current module
    * `:start` - how to start the child process (defaults to calling `__MODULE__.start_link/1`)
    * `:restart` - when the child should be restarted, defaults to `:permanent`
    * `:shutdown` - how to shut down the child

  For example:

      use AgentMap, restart: :transient, shutdown: 10_000

  See the `Supervisor` docs for more information.
  """

  @max_processes 5

  @typedoc "Return values of `start*` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid} | term}

  @typedoc "The agentmap name"
  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "The agentmap reference"
  @type agentmap :: pid | {atom, node} | name | %AgentMap{}
  @type am :: agentmap

  @typedoc "The agentmap key"
  @type key :: term

  @typedoc "The agentmap value"
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
    Common.safe_apply(fun, args)
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
      iex> pid
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
      ...>   AgentMap.start_link(f: fn -> Calc.fib(4) end, timeout: 5000)
      iex> AgentMap.get(pid, :f)
      3

  — starts server with a predefined single key `:f`.

  But if one provide actual value instead of zero-arity fun, `{:error, :badfun}`
  will be returned. If the number of arguments differs from the fun arity —
  `{:error, :badarity}` will be returned:

      iex> AgentMap.start(f: 3)
      {:error, f: :badfun}
      iex> AgentMap.start(f: {&Calc.fib/1, [4, :extraarg]})
      {:error, f: :badarity}
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
      iex> AgentMap.start(one: 42,
      ...>                two: fn -> sleep(150) end,
      ...>                three: fn -> sleep(:infinity) end,
      ...>                timeout: 100)
      {:error, one: :badfun, two: :timeout, three: :timeout}
      iex> err = AgentMap.start(one: 76,
      ...>                      two: fn -> raise "oops" end)
      iex> {:error, one: :badfun, two: {exception, _stacktrace}} = err
      iex> exception
      %RuntimeError{message: "oops"}
  """
  @spec start([{key, (() -> any)} | GenServer.option()]) :: on_start
  def start(funs_and_opts \\ [timeout: 5000]) do
    {args, opts} = prepair(funs_and_opts)
    GenServer.start(Server, args, opts)
  end

  defp _call(agentmap, req, opts) do
    req = struct(req, opts)

    case opts[:timeout] do
      nil ->
        GenServer.call(pid(agentmap), req, 5000)

      {_, timeout} ->
        GenServer.call(pid(agentmap), req, timeout)

      timeout ->
        GenServer.call(pid(agentmap), req, timeout)
    end
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
  returned from this function. This call does not change state, so a series of
  `get`-calls can and will be executed as a parallel `Task`s (see
  `max_processes/3`).

  If there are callbacks awaiting invocation, this call will be added to the end
  of the corresponding queue. If `!: true` option is given, `fun` will be
  executed immediately, passing current value as an argument.

  This call has two forms:

    * single key: `get(agentmap, key, fun, opts)`, where `fun` expected only one
      value to be passed;
    * or transaction: `get(agentmap, fun, [key1, key2, …], opts)`, where `fun`
      expected to take a list of values.

  Compare two calls:

      get(Account, &Enum.sum/1, [:alice, :bob])
      get(Account, :alice, & &1)

  — the first one returns sum of Alice and Bob balances in one operation, while
  the second one returns amount of money Alice has.

  ## Options

    * `!: true` — (boolean, `false`) to make [priority
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

  ## Special process dictionary keys

  For a single-key calls one can use `:"$key"` and `:"$value"` dictionary keys.

      iex> import AgentMap
      iex> am = AgentMap.new(k: nil)
      iex> get(am, k, fn _ -> Process.get(:"$key") end)
      :k
      iex> get(am, k, fn nil -> Process.get(:"$value") end)
      {:value, nil}
      iex> get(am, f, fn nil -> Process.get(:"$value") end)
      nil

  For a transactions, one can use `:"$keys"` and `:"$map"` keys.

      iex> am = AgentMap.new(a: nil, b: 42)
      iex> AgentMap.get(am, fn _ ->
      ...>   Process.get(:"$keys")
      ...> end, [:a, :b, :c])
      [:a, :b, :c]
      iex> AgentMap.get(am, fn [nil, 42, nil] ->
      ...>   Process.get(:"$map")
      ...> end, keys)
      %{a: nil, b: 42}

  ## Examples

      iex> import AgentMap
      iex> am = AgentMap.new()
      iex> get(am, :alice, & &1)
      nil
      iex> put(am, :alice, 42)
      iex> get(am, :alice, & &1+1)
      43
      #
      # Transactions.
      iex> put(am, :bob, 43)
      iex> get(am, &Enum.sum/1, [:alice, :bob])
      85
      # Order matters.
      iex> get(am, {&Enum.reduce/3, [0, &-/2]}, [:alice, :bob])
      1
      iex> get(am, {&Enum.reduce/3, [0, &-/2]}, [:bob, :alice])
      -1

   "Priority" calls:

      iex> import AgentMap
      iex> import :timer
      iex> am = AgentMap.new(key: 42)
      iex> cast(am, :key, fn _ -> sleep(100); 43 end)
      iex> get(am, :key, & &1, !: true)
      42
      iex> am.key # the same
      42
      iex> get(am, :key, & &1)
      43
      iex> get(am, :key, & &1, !: true)
      43
  """
  @spec get(am, ([value] -> a), [key], keyword) :: a when a: var
  @spec get(am, key, (value -> a), keyword) :: a when a: var

  # 4
  def get(agentmap, key, fun, opts)
  def get(agentmap, fun, keys, opts)

  def get(agentmap, fun, keys, opts) when is_function(fun, 1) and is_list(keys) do
    req = %Req{action: :get, data: {fun, keys}}
    _call(agentmap, req, opts)
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
  Updates `agentmap` and returns some value.

  The function `fun` is sent to the `agentmap` which invokes callback passing
  the value associated with `key` (or `nil`). The result of the invocation is
  returned from this function.

  This call has two forms:

    * single key: `get_and_update(agentmap, key, fun, opts)`, where `fun` expected
      only one value to be passed;
    * and transactions: `get_and_update(agentmap, fun, [key1, key2, …], opts)`, where
      `fun` expected to take a list of values.

  Compare two calls:

      get_and_update(account, fn [a,b] -> {:swapped, [b,a]} end, [:Alice, :Bob])
      get_and_update(account, :Alice, & {&1, &1+1000000})

  — the first one swapes Alice and Bob balances and returns `:swapped`, while
  the second one returns current Alice balance and deposits `1000000` dollars to
  it.

  In a single key calls `fun` can return:

    * a two element tuple: `{"get" value, new value}`;
    * a one element tuple `{"get" value}` (value is not changed);
    * `:id` to return a current value without changing it;
    * `:pop`, similar to `Map.get_and_update/3` this returns value with given
      `key` and removes it from `agentmap`;

   In a transaction case `fun` can return:

    * a list with values `[{"get" value, new value} | {"get" value} | :id |
      :pop]`. This returns a list of "get" values. For ex.:

          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> AgentMap.get_and_update(am, fn _ ->
          ...>   [{:get, :newvalue}, {:get}, :pop, :id]
          ...> end, [:a, :b, :c, :d])
          [:get, :get, nil, 3]
          iex> AgentMap.take(am, [:a, :b, :c, :d])
          %{a: 2, b: 2}

    * a tuple `{"get" value, [new value] | :id | :drop}`. For ex.:

          iex> import AgentMap
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> get_and_update(am, fn _ ->
          ...>   {:get, [4, 3, 2, 1]}
          ...> end, [:a, :b, :c, :d])
          :get
          iex> take(am, [:a, :b, :c, :d])
          %{a: 4, b: 3, c: 2, d: 1}
          iex> get_and_update(am, fn _ ->
          ...>   {:get, :id}
          ...> end, [:a, :b, :c, :d])
          :get
          iex> take(am, [:a, :b, :c, :d])
          %{a: 4, b: 3, c: 2, d: 1}
          iex> get_and_update(am, fn _ ->
          ...>   {:get, :drop}
          ...> end, [:b, :c])
          :get
          iex> keys(am)
          [:a, :d]

    * a one element tuple `{"get" value}`, that is the same as `{"get" value,
      :id}`;

    * `:id` to return values while not changing it;
    * `:pop` to return values while with given `keys` while removing them from
      `agentmap`';

  For ex.:

      iex> %{alice: 42, bob: 24}
      ...> |> AgentMap.new()
      ...> |> get_and_update(fn [a, b] ->
      ...>      if a > 10 do
      ...>        a = a - 10
      ...>        b = b + 10
      ...>        [{a, a}, {b, b}] # [{get, new_state}]
      ...>      else
      ...>        {{:error, "Alice does not have 10$ to give to Bob!"}, [a, b]} # {get, [new_state]}
      ...>      end
      ...>    end, [:alice, :bob])
      [32, 34]

  or:

      iex> am = AgentMap.new(alice: 42, bob: 24)
      iex> AgentMap.get_and_update(am, fn _ ->
      ...>   [:pop, :id]
      ...> end, [:alice, :bob])
      [42, 24]
      iex> AgentMap.get(am, & &1, [:alice, :bob])
      [nil, 24]

  (!) State changing transactions (such as a `get_and_update`) will block all
  the involving states. For ex.:

      iex> import :timer
      iex> %{alice: 42, bob: 24, chris: 0}
      ...> |> AgentMap.new()
      ...> |> AgentMap.get_and_update(
      ...>      &sleep(1000) && {:slept_well, &1},
      ...>      [:alice, :bob]
      ...>    )
      :slept_well

  will block the possibility to `get_and_update`, `update`, `cast` and even
  non-priority `get` on `:alice` and `:bob` keys for 1 sec. Nonetheless values
  are always available for "priority" `get` calls. `chris` state is not blocked.

  Transactions are *Isolated* and *Durabled* (see, ACID model). *Atomicity* can
  be implemented inside callbacks and *Consistency* is out of question here as
  its the application level concept.

  ## Options

    * `!: true` — (boolean, `false`) to make [priority
      calls](#module-priority-calls-true). `key` could have an associated queue
      of callbacks, awaiting of execution. If such queue exists, "priority"
      version will add call to the begining of the queue (via "selective
      receive");
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

  Transactions:

      iex> import AgentMap
      iex> am = new(uno: 22, dos: 24)
      iex> get_and_update(am, fn [u, d] ->
      ...>   [{u, d}, {d, u}]
      ...> end, [:uno, :dos])
      [22, 24]
      iex> get(am, & &1, [:uno, :dos])
      [24, 22]
      #
      iex> get_and_update(am, fn _ -> :pop end, [:dos])
      [22]
      iex> has_key?(am, :dos)
      false
      #
      iex> get_and_update(am, :dos, fn _ -> {:get} end)
      :get
      iex> has_key?(am, :dos)
      false
      #
      iex> put(am, :tres, 42)
      iex> put(am, :cuatro, 44)
      iex> get_and_update(am, fn _ ->
      ...>   [:id, {nil, :_}, {:_, nil}, :pop]
      ...> end, [:uno, :dos, :tres, :cuatro])
      [24, nil, :_, 44]
      iex> get(am, & &1, [:uno, :dos, :tres, :cuatro])
      [24, :_, nil, nil]
  """
  # 4
  @type cb(a) ::
          (value ->
             {a}
             | {a, value}
             | :pop
             | :id)

  @type cb_t(a) ::
          ([value] ->
             {a}
             | {a, [value] | :drop | :id}
             | [{any} | {any, value} | :pop | :id]
             | :pop
             | :id)

  @spec get_and_update(am, key, cb(a), keyword) :: a | value
        when a: var
  @spec get_and_update(am, cb_t(a), [key], keyword) :: a | [value]
        when a: var

  def get_and_update(agentmap, key, fun, opts \\ [!: false, timeout: 5000])

  def get_and_update(agentmap, fun, keys, opts) when is_function(fun, 1) and is_list(keys) do
    unless keys == uniq(keys) do
      raise """
            expected uniq keys for `update`, `get_and_update` and
            `cast` transactions. Got: #{inspect(keys)}. Please
            check #{inspect(keys -- uniq(keys))} keys.
            """
            |> String.replace("\n", " ")
    end

    req = %Req{action: :get_and_update, data: {fun, keys}}
    _call(agentmap, req, opts)
  end

  def get_and_update(agentmap, key, fun, opts) when is_function(fun, 1) do
    # opts =
    #   Keyword.put_new(opts, :!, false)

    req = %Req{action: :get_and_update, data: {key, fun}}
    _call(agentmap, req, opts)
  end

  ##
  ## UPDATE
  ##

  @doc """
  Updates the values of `agentmap`.

  This function always returns the same `agentmap` to make piping work.

  Keep in mind that

      update(am, key, fun, opts)
      update(am, fun, keys, opts)

  is no more than a syntax sugar for

      get_and_update(am, key, &{:ok, fun.(&1)}, opts)
      get_and_update(am, &{:ok, fun.(&1)}, keys, opts)

  So `fun`s for transactions can return:

    * a list of new values;
    * `:id` — leave values as they are;
    * `:drop`.

  ## Options

  The same as for `get_and_update/4`.

  ## Examples

      update(account, :alice, & &1+1000000)
      update(account, fn [a,b] -> [b,a] end, [:alice, :bob])

  — the first one call deposits 1000000 dollars to Alices balance, while the
  second swapes balances of Alice and Bob.

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

  For ex.:

      iex> am = AgentMap.new(a: 42, b: 24, c: 33, d: 51)
      iex> AgentMap.get(am, & &1, [:a, :b, :c, :d])
      [42, 24, 33, 51]
      iex> am
      ...> |> AgentMap.update(&Enum.reverse/1, [:a, :b])
      ...> |> AgentMap.get(& &1, [:a, :b, :c, :d])
      [24, 42, 33, 51]
      iex> am
      ...> |> AgentMap.update(fn _ -> :drop end, [:a, :b])
      ...> |> AgentMap.keys()
      [:c, :d]
      iex> am
      ...> |> AgentMap.update(fn _ -> :drop end, [:c])
      ...> |> AgentMap.update(:d, fn _ -> :drop end)
      ...> |> AgentMap.get(& &1, [:c, :d])
      [nil, :drop]
  """
  # 4
  @spec update(am, key, (value -> value), keyword) :: am
  @spec update(am, ([value] -> [value] | :drop | :id), [key], keyword) :: am
  def update(agentmap, key, fun, opts \\ [!: false, timeout: 5000])

  def update(agentmap, fun, keys, opts) when is_function(fun, 1) and is_list(keys) do
    # opts =
    #   Keyword.put_new(opts, :!, false)

    req = %Req{action: :update, data: {fun, keys}}
    _call(agentmap, req, opts)
  end

  def update(agentmap, key, fun, opts) when is_function(fun, 1) do
    get_and_update(agentmap, key, &{:ok, fun.(&1)}, opts)
  end

  def update(agentmap, key, initial, fun) when is_function(fun, 1) do
    update(agentmap, key, initial, fun, [])
  end

  @doc """
  For compatibility with `Map` API, `update(agentmap, key, initial, fun)` call
  is supported.

      iex> AgentMap.new(a: 42)
      ...> |> AgentMap.update(:a, :value, & &1+1)
      ...> |> AgentMap.update(:b, :value, & &1+1)
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
  Perform `cast` ("fire and forget"). Works the same as `update/4` but uses
  `GenServer.cast/2`.

  ## Options

    * `!: true` — (boolean, `false`) to make [priority
      calls](#module-priority-calls-true). `key` could have an associated queue
      of callbacks, awaiting of execution. If such queue exists, "priority"
      version will add call to the begining of the queue (via "selective
      receive");

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `timeout: {:break, pos_integer}` — to throw out from queue or cancel a
      running call upon the occurence of a timeout. See [timeout
      section](#module-timeout).

    As this call uses `GenServer.cast/2`, `timeout: timeout` option is not
    available.
  """
  @spec cast(am, key, (value -> value), keyword) :: am
  @spec cast(am, ([value] -> [value]), [key], keyword) :: am
  @spec cast(am, ([value] -> :drop | :id), [key], keyword) :: am
  def cast(agentmap, key, fun, opts \\ [!: false])

  def cast(agentmap, fun, keys, opts) when is_function(fun, 1) and is_list(keys) do
    req = %Req{action: :cast, data: {fun, keys}}
    _cast(agentmap, req, opts)
  end

  def cast(agentmap, key, fun, opts) when is_function(fun, 1) do
    req = %Req{action: :get_and_update, data: {key, &{:ok, fun.(&1)}}}
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

  will run for 200 ms as `agentmap` can parallelize any sequence of `get/3`
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

    * `!: false` — (boolean, `true`) to put this call in the
    [queue](#module-priority-calls-true);

    * `:timeout` — (timeout, `5000`).

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
  `agentmap` doesn't contain `key`. If `agentmap` contains the given `key`, the
  corresponding value is returned. If `agentmap` doesn't contain `key`, a
  `KeyError` exception is raised.

  Returns the current value, unless `!: false` option is given.

  ## Options

    * `!: false` — (boolean, `true`) to put this call in the
    [queue](#module-priority-calls-true);

    * `:timeout` — (timeout, `5000`).

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
  Removes and returns the value associated with `key` from `agentmap`. If there
  is no such `key` in `agentmap`, `default` is returned (`nil`).

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
  Returns a snapshot with a key-value pairs taken from `agentmap`. Keys that are
  not in `agentmap` are ignored.

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

  By default, returns `agentmap` without waiting for actual drop happens.

  ## Options

    * `!: true` — (`boolean`, `false`) to make [priority
      calls](#module-priority-calls-true);

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`) if `cast: false` is
      given;

    * `:cast` — (`boolean`, `true`) wait for actual drop happens?

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

defmodule AgentMap do
  @behaviour Access

  @enforce_keys [:link]
  defstruct @enforce_keys

  alias AgentMap.{Helpers, Server, Req}

  import Helpers, only: :macros

  @moduledoc """
  The `AgentMap` can be seen as a stateful `Map` that parallelize operations
  made on different keys. Basically, it can be used as a cache, memoization,
  computational framework and, sometimes, as a `GenServer` replacement.

  Underneath it's a `GenServer` that holds a `Map`. If an `update/4`,
  `update!/4`, `get_and_update/4` or `cast/4` happend (or too many `get/4` calls
  on the same key), a special temporary process called "worker" is spawned. The
  message queue of that process became the queue of the calls waiting for
  invocation. `AgentMap` respects the order in which calls are made and supports
  transactions — operations that simultaniously change a group of values.

  Also, the special struct `%AgentMap{}` can be created via the `new/1`
  function. This allows to use the `Enumerable` protocol and take benefit from
  the `Access` behaviour.

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

  Or start as an `Agent`:

      iex> {:ok, pid} = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.put(:a, 1)
      ...> |> AgentMap.get(:a)
      1
      iex> am = AgentMap.new(pid)
      iex> am.a
      1

  Let's look at the more complicated example (memoization):

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

  Also, take a look at the example in the `test/memo.ex`.

  Also, `AgentMap` provides possibility to make transactions (operations on
  multiple keys). Let's see an accounting demo:

      defmodule Account do
        def start_link() do
          AgentMap.start_link(name: __MODULE__)
        end

        def stop() do
          AgentMap.stop(__MODULE__)
        end

        @doc \"""
        Returns `{:ok, balance}` for account or `:error` if
        there no such account.
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
                       # as it would create `nil` value key

            balance when balance > amount ->
              balance = balance - amount
              {{:ok, balance}, balance}

            _balance ->
              # Return `:error`, while not changing value.
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
        Closes account. Returns `:ok` if the account existed
        and `:error` in the other case.
        \"""
        def close(account) do
          AgentMap.pop(__MODULE__, account) && :ok || :error
        end

        @doc \"""
        Opens account. Returns `:error` if account exists or
        `:ok` in other case.
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
  `Enumerable` protocol implemented for `%AgentMap{}`, so `Enum` should work as
  expected:

      iex> %{answer: 42}
      ...> |> AgentMap.new()
      ...> |> Enum.empty?()
      false

  Similary, `AgentMap` follows the `Access` behaviour:

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> am.a
      42

  (!) `put_in` operator is not working properly.

  ## Options

  ### Priority calls (`!: true`)

  Most of the functions support `!: true` option to make out-of-turn
  ("priority") calls.

  On each key, no more than fifth `get/4` calls can be executed simultaneously.
  If `6`-th `get/4` call, `update!/4`, `update/4`, `cast/4` or
  `get_and_update/4` came, a special worker process will be spawned that became
  the holder of the execution queue. It's the FIFO queue, but [selective
  receive](http://learnyousomeerlang.com/more-on-multiprocessing) can be used to
  provide the possibility for some callbacks to be executed in the order of
  preference (out-of-turn).

  For example:

      iex> import :timer
      iex> am = AgentMap.new(state: :ready)
      iex> am
      ...> |> AgentMap.cast(:state, fn _ -> sleep(50); :steady end)
      ...> |> AgentMap.cast(:state, fn _ -> sleep(50); :stop end)
      ...> |> AgentMap.cast(:state, fn _ -> sleep(50); :go! end, !: true)
      ...> |> AgentMap.fetch(:state)
      {:ok, :ready}
      # AgentMap.fetch/2 immediately returns the
      # current state. Worker executes first `cast`.
      #
      iex> AgentMap.queue_len(am, :state)
      2
      # [:go!, :stop]
      iex> AgentMap.queue_len(am, :state, !: true)
      1
      # [:go!]
      iex> [AgentMap.get(am, :state),
      ...>  AgentMap.get(am, :state, !: true),
      ...>  am.state]
      [:ready, :ready, :ready]
      iex> AgentMap.get(am, :state, & &1, !: true)
      :steady
      # get! calls will have the highest priority.
      # executes: :go!, queue: [:stop]
      iex> AgentMap.get(am, :state)
      :stop

  Keep in mind that selective receive can lead to performance issues if the
  message queue becomes too fat. So it was decided to disable selective receive
  each time message queue of the worker process has more that `100` items. It
  will be turned on again when message queue became empty.

  ### Timeout

  A timeout is an integer greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the atom `:infinity` to wait indefinitely. By default it
  is set to the `5000 ms` = `5 sec`.

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the atom `:infinity` to wait indefinitely. If no result
  is received within the specified time, the caller exits. By default it's equal
  to `5000` ms. This value could be given as `:timeout` option, or separately,
  so:

      get_and_update(agentmap, :key, fun)
      get_and_update(agentmap, :key, fun, 5000)
      get_and_update(agentmap, :key, fun, timeout: 5000)
      get_and_update(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.


  If no result is received within the specified time, the caller exits, (!) but
  the callback will remain in a queue!

      iex> import :timer
      iex> am =
      ...>   AgentMap.new(key: 42)
      iex> AgentMap.cast(am, :key, & sleep(50); &1+1)
      iex> Process.flag(:trap_exit, true)
      false
      iex> Process.info(self(), :message_queue_len)
      {:message_queue_len, 0}
      iex> AgentMap.put(am, :key, 24, timeout: 50)
      iex> Process.info(self(), :message_queue_len)
      {:message_queue_len, 1}
      iex> AgentMap.get(am, :key, & &1)
      24

  To change this behaviour, provide `{:drop, timeout}` value. For instance, this
  calls:

      get(agentmap, :key, & &1, timeout: {:drop, 5000})

  will timeout after `5000` ms and will be dropped from queue.

  Also, special `{:hard, pos_integer}` is supported as a timeout value. Callback
  for the next call will be wrapped in a `Task` that will be shutdowned in
  `6000` ms:

      import :timer
      AgentMap.cast(
        agentmap,
        :key,
        fn _ -> sleep(:infinity) end,
        deadline: {:hard, 6000}
      )

  ### Safe calls

  This call:

      get(agentmap, :key, fn _ -> 42 / 0 end, safe: false)

  will lead to the ungraceful falling of the `AgentMap` server. This is rarely a
  desirable behaviour, so by default, every callback is wrapped into a
  `try-catch`. This can be turned of, providing `safe: false`.

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

  @typedoc "Anonymous function, `{fun, args}` or MFA triplet"
  @type f(a, r) :: (a -> r) | {(... -> r), [a | any]} | {module, atom, [a | any]}

  @typedoc "Anonymous function with zero arity, pair `{fun/length(args), args}` or corresponding MFA tuple"
  @type f(r) :: (() -> r) | {(... -> r), [any]} | {module, atom, [any]}

  @typedoc "Option for most of the calls"
  @type option :: {:!, boolean} | {:timeout, timeout} | {:safe, boolean}

  # @typedoc "Options for most of the calls"
  # @type options :: [option] | timeout

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

  ## ##

  @doc """
  Returns a new empty `agentmap`.

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

  As the only argument, states keyword can be provided or already started
  agentmap.

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
  def new(list) when is_list(list), do: new(Map.new(list))

  def new(%{} = states) when is_map(states) do
    states =
      for {key, state} <- states do
        {key, fn -> state end}
      end

    {:ok, am} = start_link(states)
    new(am)
  end

  def new(am), do: %__MODULE__{link: GenServer.whereis(am)}

  @doc """
  Creates an agentmap from an `enumerable` via the given transformation
  function. Duplicated keys are removed; the latest one prevails.

  ## Examples

      iex> am = AgentMap.new([:a, :b], fn x -> {x, x} end)
      iex> AgentMap.take(am, [:a, :b])
      %{a: :a, b: :b}
  """
  @spec new(Enumerable.t(), (term -> {key, value})) :: am
  def new(enumerable, transform) do
    new(Map.new(enumerable, transform))
  end

  # common for start_link and start
  # separate GenServer options and funs
  defp separate(funs_and_opts) do
    {opts, funs} =
      funs_and_opts
      |> Enum.reverse()
      |> Enum.split_while(fn {k, _} ->
        k in [:name, :timeout, :debug, :spawn_opt]
      end)

    {Enum.reverse(funs), opts}
  end

  defp prepair(funs_and_opts) do
    {funs, opts} = separate(funs_and_opts)
    timeout = opts[:timeout] || 5000

    # Turn off global timeout.
    opts = Keyword.put(opts, :timeout, :infinity)

    {funs, opts, timeout}
  end

  @doc """
  Starts an `AgentMap` server linked to the current process with the given
  function.

  The only argument is a keyword, elements of which are `GenServer.options` and
  pairs `{key, fun/0}`, where `fun/0` can take the form of a zero arity
  anonymous fun, pair `{fun, args}` or MFA-tuple. For each key, fun is executed
  in a separate `Task`.

  ## Options

  The `:name` option is used for registration as described in the module
  documentation.

  If the `:timeout` option is present, the agentmap is allowed to spend at most
  the given number of milliseconds on the whole process of initialization or it
  will be terminated and the start function will return `{:error, :timeout}`.

  If the `:debug` option is present, the corresponding function in the [`:sys`
  module](http://www.erlang.org/doc/man/sys.html) will be invoked.

  If the `:spawn_opt` option is present, its value will be passed as options to
  the underlying process as in `Process.spawn/4`.

  ## Return values

  If the server is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a server with the
  specified name already exists, the function returns `{:error,
  {:already_started, pid}}` with the PID of that process.

  If one of the callbacks fails, the function returns `{:error, [{key,
  error_reason}]}`, where `error_reason` is `:timeout`, `:badfun`, `:badarity`,
  `{:exit, reason}` or an arbitrary exception. For example:

      iex> AgentMap.start_link(f: fn -> Calc.fib(4) end)
      iex> AgentMap.start_link(f: {Calc, :fib, [4]})
      iex> AgentMap.start_link(f: {&Calc.fib/1, [4]})
      iex> AgentMap.start_link(f: {&Calc.fib(&1), [4]}))
      iex> AgentMap.start_link(f: {fn -> Calc.fib(4) end, []})
      ...> |> elem(1)
      ...> |> AgentMap.get(:f)
      3

  If one provide actual value instead of zero-arity fun, `{:error, :badfun}`
  will be returned. If the number arguments is equal to the needed arity —
  `{:error, :badarity}` will be returned:

      iex> AgentMap.start(f: 3)
      {:error, f: :badfun}
      iex> AgentMap.start(f: {&Calc.fib/1, [4, :extraarg]})
      {:error, f: :badarity}
      # … and so on

  ## Examples

      iex> {:ok, pid} =
      ...>   AgentMap.start_link(key: fn -> 42 end)
      iex> AgentMap.get(pid, :key, & &1)
      42
  """
  @spec start_link([{key, f(any)} | GenServer.option()]) :: on_start
  def start_link(funs_and_opts \\ [timeout: 5000]) do
    {funs, opts, timeout} = prepair(funs_and_opts)
    GenServer.start_link(Server, {funs, timeout}, opts)
  end

  @doc """
  Starts an `AgentMap` in an unlinked process.

  See `start_link/2` for details.

  ## Examples

      iex> import :timer
      iex> AgentMap.start(one: 42,
      ...>                two: fn -> sleep(150) end,
      ...>                three: fn -> sleep(:infinity) end,
      ...>                timeout: 100)
      {:error, one: :badfun, two: :timeout, three: :timeout}
      iex> AgentMap.start(one: :foo,
      ...>                one: :bar,
      ...>                three: fn -> sleep(:infinity) end,
      ...>                timeout: 100)
      {:error, one: :exists}
      iex> err = AgentMap.start(one: 76,
      ...>                      two: fn -> raise "oops" end)
      iex> {:error, one: :badfun, two: {exception, _stacktrace}} = err
      iex> exception
      %RuntimeError{message: "oops"}
  """
  @spec start([{key, f(any)} | GenServer.option()]) :: on_start
  def start(funs_and_opts \\ [timeout: 5000]) do
    {funs, opts, timeout} = prepair(funs_and_opts)
    GenServer.start(Server, {funs, timeout}, opts)
  end

  defp _timeout(opts) do
    case opts[:timeout] do
      nil ->
        5000

      {_, timeout} ->
        timeout

      timeout ->
        timeout
    end
  end

  defp _call(agentmap, req, opts) do
    req = struct(req, opts)
    GenServer.call(pid(agentmap), req, _timeout(opts))
  end

  defp _cast(agentmap, %Req{} = req, opts) do
    req = struct(req, opts)
    GenServer.cast(pid(agentmap), req)
    agentmap
  end

  defp _call_or_cast(agentmap, %Req{} = req, opts) do
    if Keyword.get(opts, :cast, true) do
      _cast(agentmap, req, opts)
    else
      _call(agentmap, req, opts)
    end
  end

  ##
  ## GET
  ##

  @doc """
  Invokes `fun`, passing value as an argument. If it's lost — `nil` will be used
  as a value. Returns result of the invocation. This call does not change state,
  so it can and will be executed concurrently. No more than `max_processes` will
  be used per key (see `max_processes/2`). If there are callbacks awaiting
  invocation, this call will be added to the end of the corresponding queue
  (unless `!: true` is given).

  This call has two forms:

    * single key: `get(agentmap, key, fun)`, where `fun` expected only one value
      to be passed;
    * or transaction: `get(agentmap, fun, [key1, key2, …])`, where `fun`
      expected to take a list of values.

  Compare two calls:

      AgentMap.get(Account, &Enum.sum/1, [:alice, :bob])
      AgentMap.get(Account, :alice, & &1)

  — the first one returns sum of Alice and Bob balances in one operation, while
  the second one returns amount of money Alice has.

  ## Options

  Provide `safe: false` to make [unsafe calls](#module-options)

  Provide `timeout` integer value, greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the `:infinity` to wait indefinitely. If no result is
  received within the specified time, the caller exits. By default it's equal to
  `5000` ms. This value could be given as `:timeout` option, or separately, so:

      AgentMap.get(agentmap, :key, fun)
      AgentMap.get(agentmap, :key, fun, 5000)
      AgentMap.get(agentmap, :key, fun, timeout: 5000)
      AgentMap.get(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.

  See also `deadline` [option](#module-deadline). For `!: true` calls only
  hard-`deadline` is supported as this calls are never queued.

  Provide `!: true` to make ["priority" calls](#module-options). Every key could
  have an associated queue of callbacks awaiting of execution, "priority"
  version allows to execute given `fun` in a separate `Task`, immediately at the
  moment of call (regardless of `max_processes`). Thus calls are never queued.

  ## Special process dictionary keys

  For a single-key calls one can use `:"$key"` and `:"$value"` dictionary keys.

      iex> am = AgentMap.new(k: nil)
      iex> AgentMap.get(am, k, fn _ -> Process.get(:"$key") end)
      :k
      iex> AgentMap.get(am, k, fn nil -> Process.get(:"$value") end)
      {:value, nil}
      iex> AgentMap.get(am, f, fn nil -> Process.get(:"$value") end)
      nil

  For a transactions one can use `:"$keys"` and `:"$map"` keys.

      iex> am = AgentMap.new(a: nil, b: 42)
      iex> AgentMap.get(am, fn _ -> Process.get(:"$keys") end, [:a, :b, :c])
      [:a, :b, :c]
      iex> AgentMap.get(am, fn [nil, 42, nil] ->
      ...>   Process.get(:"$map")
      ...> end, keys)
      %{a: nil, b: 42}

  ## Examples

      iex> am = AgentMap.new()
      iex> AgentMap.get(am, :alice, & &1)
      nil
      iex> AgentMap.put(am, :alice, 42)
      iex> AgentMap.get(am, :alice, & &1+1)
      43
      #
      # Transactions.
      iex> AgentMap.put(am, :bob, 43)
      iex> AgentMap.get(am, &Enum.sum/1, [:alice, :bob])
      85
      # Order matters.
      iex> AgentMap.get(am, {&Enum.reduce/3, [0, &-/2]}, [:alice, :bob])
      1
      iex> AgentMap.get(am, {&Enum.reduce/3, [0, &-/2]}, [:bob, :alice])
      -1

   "Priority" calls:

      iex> import :timer
      iex> am = AgentMap.new(key: 42)
      iex> AgentMap.cast(am, :key, fn _ -> sleep(100); 43 end)
      iex> AgentMap.get(am, :key, & &1, !: true)
      42
      iex> am.key # the same
      42
      iex> AgentMap.get(am, :key, & &1)
      43
      iex> AgentMap.get(am, :key, & &1, !: true)
      43
  """
  @spec get(am, f([value], a), [key], [option]) :: a when a: var
  @spec get(am, key, f(value, a), [option]) :: a when a: var

  # 4
  def get(agentmap, key, fun, opts)
  def get(agentmap, fun, keys, opts)

  def get(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    req = %Req{action: :get, data: {fun, keys}}
    _call(agentmap, req, opts)
  end

  def get(agentmap, key, fun, opts) when is_fun(fun, 1) do
    req = %Req{action: :get, data: {key, fun}}
    _call(agentmap, req, opts)
  end

  # 3
  def get(agentmap, key, default)

  def get(agentmap, fun, keys) when is_fun(fun, 1) and is_list(keys) do
    req = %Req{action: :get, data: {fun, keys}}
    _call(agentmap, req, [])
  end

  def get(agentmap, key, fun) when is_fun(fun, 1) do
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
    case fetch(agentmap, key) do
      {:ok, value} ->
        value
      :error ->
        fun.()
    end
  end

  @doc """
  The same as `get(agentmap, key, nil)`.

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
  Updates `agentmap` and returns some value. The callback `fun` will be added to
  the queue. `fun` is invoked passing corresponding `values` or `nil`(s) for the
  lost one(s).

  This call has two forms:

    * single key: `get_and_update(agentmap, key, fun)`, where `fun` expected
      only one value to be passed;
    * and transactions: `get_and_update(agentmap, fun, [key1, key2, …])`, where
      `fun` expected to take a list of values.

  Compare two calls:

      get_and_update(account, fn [a,b] -> {:swapped, [b,a]} end, [:Alice, :Bob])
      get_and_update(account, :Alice, & {&1, &1+1000000})

  — the first one swapes Alice and Bob balances and returns `:swapped`, while
  the second one returns current Alice balance and deposits `1000000` dollars to
  it.

  In a single key calls `fun` can return:

    * a two element tuple: `{"get" value, new value}`;
    * a one element tuple `{"get" value}`;
    * `:id` to return current value while not changing it;
    * `:pop`, similar to `Map.get_and_update/3` it returns value with given
      `key` and removes it from `agentmap`.

    * `{:chain, {key, fun}, new_value}` — to not return value, but initiate
      another `get_and_update/4` with given `key` and `fun` pair;
    * `{:chain, {fun, keys}, new_value}` — to not return value, but initiate
      transaction call `get_and_update/4` with given `fun` and `keys` pair.

  In a transactions it can return:

    * a two element tuple `{"get" value, [new values]}`;
    * a two element tuple `{"get" value, :drop}` — to remove values with given
      keys;
    * a two element tuple `{"get" value, :id}` — to return "get" value while not
      changin values;

    * a one element tuple `{"get" value}`, that is the same as `{"get" value,
      :id}`;

    * a list with values `[{"get" value} or {"get" value, new value} or :id or
      :pop]`. This returns a list of values as it was made a group of single key
      calls;

    * `:id` to return values while not changing it;
    * `:pop` to return values while with given `keys` while removing them from
      `agentmap`';

    * `{:chain, {key, fun}, new_value}` — to not return value, but initiate
      another `get_and_update/4` with given `key` and `fun` pair;
    * `{:chain, {fun, keys}, new_value}` — to not return value, but initiate
      transaction `get_and_update/4` call with given `fun` and `keys` pair.

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

  Provide `safe: false` to make [unsafe calls](#module-options).

  Provide `!: true` to make [priority calls](#module-options). Values could have
  an associated queue of callbacks, awaiting of execution. If such queue exists,
  "priority" version will add call to the begining of the queue (via "selective
  receive").

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

  Chain calls (used rarely):

      iex> import AgentMap
      iex> am = new(uno: 24, dos: 33, tres: 42)
      iex> call = {:dos, fn _ -> {:get, :dos} end}
      iex> get_and_update(am, :uno, fn _ ->
      ...>   {:chain, call, :uno}
      ...> end)
      :get
      iex> get(am, & &1, [:uno, :dos])
      [:uno, :dos]
      #
      # transaction chain calls:
      #
      iex> call = {fn _ -> {:get, [2,3]} end, [:dos, :tres]}
      iex> get_and_update(am, :uno, fn _ ->
      ...>   {:chain, call, 1}
      ...> end)
      :get
      iex> get(am, & &1, [:uno, :dos, :tres])
      [1, 2, 3]
      #
      iex> call = {:uno, fn _ -> {:get, :u} end}
      iex> get_and_update(am, fn _ ->
      ...>   {:chain, call, [:d, :t]}
      ...> end, [:dos, :tres])
      :get
      iex> get(am, & &1, [:uno, :dos, :tres])
      [:u, :d, :t]
  """
  # 4
  @type callback(a) ::
          f(
            value,
            {a}
            | {a, value}
            | :pop
            | :id
            | {:chain, {key, callback(a)}, value}
            | {:chain, {callback_t(a), [key]}, value}
          )

  @type callback_t(a) ::
          f(
            [value],
            {a}
            | {a, [value] | :drop | :id}
            | [{any} | {any, value} | :pop | :id]
            | :pop
            | :id
            | {:chain, {key, callback(a)}, value}
            | {:chain, {callback_t(a), [key]}, value}
          )

  @spec get_and_update(am, key, callback(a), [option]) :: a | value
        when a: var
  @spec get_and_update(am, callback_t(a), [key], [option]) :: a | [value]
        when a: var

  def get_and_update(agentmap, key, fun, opts \\ [!: false, safe: true, timeout: 5000])

  def get_and_update(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    # opts =
    #   opts
    #   |> Keyword.put_new(:!, false)
    #   |> Keyword.put_new(:safe, true)

    req = %Req{action: :get_and_update, data: {fun, keys}}
    _call(agentmap, req, opts)
  end

  def get_and_update(agentmap, key, fun, opts) when is_fun(fun, 1) do
    # opts =
    #   opts
    #   |> Keyword.put_new(:!, false)
    #   |> Keyword.put_new(:safe, true)

    req = %Req{action: :get_and_update, data: {key, fun}}
    _call(agentmap, req, opts)
  end

  ##
  ## UPDATE
  ##

  @doc """
  Updates the values of `agentmap`.
  Returns the same `agentmap`.

  Keep in mind that

      update(am, key, fun, opts)
      update(am, fun, keys, opts)

  are no more than a syntax sugar for

      get_and_update(am, key, &{:ok, apply(fun, [&1])}, opts)
      get_and_update(am, &{:ok, apply(fun, [&1])}, keys, opts)

  So `fun`s for transactions can return:

    * a list of new values;
    * `:id` — directs to leave values as they are;
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
  @spec update(am, key, f(any, any), [option]) :: am
  @spec update(am, f([any], [any]), [key], [option]) :: am
  @spec update(am, f([any], :drop | :id), [key], [option]) :: am
  def update(agentmap, key, fun, opts \\ [!: false, safe: true, timeout: 5000])

  def update(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    # opts =
    #   opts
    #   |> Keyword.put_new(:!, false)
    #   |> Keyword.put_new(:safe, true)

    req = %Req{action: :update, data: {fun, keys}}
    _call(agentmap, req, opts)
  end

  def update(agentmap, key, fun, opts) when is_fun(fun, 1) do
    get_and_update(agentmap, key, &{:ok, Helpers.apply(fun, [&1])}, opts)
  end

  def update(agentmap, key, initial, fun) when is_fun(fun, 1) do
    update(agentmap, key, initial, fun, [])
  end

  @doc """
  For compatibility with `Map` API, `update(agentmap, key, initial, fun)` call
  supported.

      iex> AgentMap.new(a: 42)
      ...> |> AgentMap.update(:a, :value, & &1+1)
      ...> |> AgentMap.update(:b, :value, & &1+1)
      ...> |> AgentMap.take([:a,:b])
      %{a: 43, b: :value}
  """
  # 5
  @spec update(am, key, any, f(any, any), [option]) :: am
  def update(agentmap, key, initial, fun, opts) when is_fun(fun, 1) do
    update(
      agentmap,
      key,
      fn value ->
        if Process.get(:"$value") do
          Helpers.apply(fun, [value])
        else
          initial
        end
      end,
      opts
    )
  end

  @doc """
  Updates `key` with the given function.

  If `key` is present in `agentmap`, `fun` is invoked with value as argument and
  its result is used as the new value of `key`. If `key` is not present in
  `agentmap`, a `KeyError` exception is raised.

  ## [Option]

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
  def update!(agentmap, key, fun, opts \\ [!: false, safe: true, timeout: 5000]) when is_fun(fun, 1) do
    update(
      agentmap,
      key,
      fn value ->
        if Process.get(:"$value") do
          Helpers.apply(fun, [value])
        else
          raise KeyError, key: key
        end
      end,
      opts
    )
  end

  @doc """
  Alters the value stored under `key`, but only if `key` already exists in
  `agentmap`.

  If `key` is not present in `agentmap`, a `KeyError` exception is raised.

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
  @spec replace!(agentmap, key, value, [!: boolean, timeout: timeout] | timeout) :: agentmap
  def replace!(agentmap, key, value, opts \\ [!: false, timeout: 5000]) do
    fun = fn _ ->
      if Process.get(:"$value") do
        {:ok, value}
      else
        raise KeyError, key: key
      end
    end
  end

  ##
  ## CAST
  ##

  @doc """
  Perform `cast` ("fire and forget"). Works the same as `update/4` but uses
  `GenServer.cast/2`.
  """
  @spec cast(am, key, f(value, value), !: boolean) :: am
  @spec cast(am, f([value], [value]), [key], !: boolean) :: am
  @spec cast(am, f([value], :drop | :id), [key], !: boolean) :: am
  def cast(agentmap, key, fun, opts \\ [!: false])

  def cast(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    req = %Req{action: :cast, data: {fun, keys}}
    _cast(agentmap, req, opts)
  end

  def cast(agentmap, key, fun, opts) when is_fun(fun, 1) do
    req = %Req{action: :get_and_update, data: {key, &{:ok, Helpers.apply(fun, [&1])}}}
    _cast(agentmap, req, opts)
  end

  @doc """
  Sets the `:max_processes` value for the given `key`.
  Returns the old value.

  `agentmap` can execute `get` calls on the same key concurrently. `max_processes`
  option specifies number of processes per key used, minus one thread for the
  process holding the queue. Default value is `5`.

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
  def max_processes(agentmap, key, value) do
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

  ## [Option]

  Provide `!: false` to put this call to the queue. See [corresponding docs
  section](#module-[option]). If so, `timeout` can be
  [provided](#module-timeout).

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
  @spec fetch(agentmap, key, [option]) :: {:ok, value} | :error
  def fetch(agentmap, key, opts \\ [!: true]) do
    if Keyword.get(opts, :!, true) do
      req = %Req{action: :fetch, data: key}
      _call(agentmap, req, opts)
    else
      get(agentmap, key, fn v ->
        has_value? = Process.get(:"$value")
        (has_value? && {:ok, v}) || :error
      end)
    end
  end

  @doc """
  Fetches the value for a specific `key` from `agentmap`, erroring out if
  `agentmap` doesn't contain `key`. If `agentmap` contains the given `key`, the
  corresponding value is returned. If `agentmap` doesn't contain `key`, a
  `KeyError` exception is raised.

  Returns value *immediately*, unless `!: false` option is given.

  ## [Option]

  Provide `!: false` to put this call in the queue. See [corresponding docs
  section](#module-[option]). If so, `timeout` can be
  [provided](#module-timeout).

      iex> import :timer
      iex> am = AgentMap.new()
      iex> AgentMap.cast(am, :b, fn _ ->
      ...>   sleep(50); 42
      ...> end)
      iex> AgentMap.fetch!(am, :b)
      ** (KeyError) key :b not found
      iex> AgentMap.fetch!(am, :b, !: false)
      {:ok, 42}

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.fetch!(am, :a)
      1
      iex> AgentMap.fetch!(am, :b)
      ** (KeyError) key :b not found
  """
  @spec fetch!(agentmap, key, !: boolean) :: value | no_return
  def fetch!(agentmap, key, opts \\ [!: true]) do
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
  @spec has_key?(agentmap, key, [option]) :: boolean
  def has_key?(agentmap, key, opts \\ [!: true]) do
    match?({:ok, _}, fetch(agentmap, key, opts))
  end

  @doc """
  Removes and returns the value associated with `key` from `agentmap`. If there
  is no such `key` in `agentmap`, `default` is returned (`nil`).

  The same (but slowly) can be achieved with

      get_and_update(agentmap, key, fn v ->
        has_value? = Process.get(:"$value")
        has_value? && :pop || {default}
      end)

  ## [Option]

  Provide `!: false` to make non-priority calls. See [corresponding docs
  section](#module-[option]).

  Also, `timeout` can be [provided](#module-timeout).

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
  @spec pop(agentmap, key, any, [option]) :: value | any
  def pop(agentmap, key, default \\ nil, opts \\ [!: true, timeout: 5000]) do
    opts = Keyword.put_new(opts, :!, true)
    _call(agentmap, %Req{action: :pop, data: {key, default}}, opts)
  end

  @doc """
  Puts the given `value` under the `key` in the `agentmap`.

  Returns *immediately*, but `cast: false` option can be provided to return only
  when the actual call is complete.

  ## [Option]

  By default this call is a ["priority"](#module-[option]). Provide `!: false` to
  make non-priority calls.

  Provide `cast: false` to use `GenServer.call/3` instead of `GenServer.cast/2`
  to make this call. If so, `timeout` can be [provided](#module-timeout).

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
  @spec put(agentmap, key, value, [option | {:cast, boolean}]) :: agentmap
  def put(agentmap, key, value, opts \\ [!: true, cast: true]) do
    opts =
      opts
      |> Keyword.put_new(:!, true)
    # |> Keyword.put_new(:cast, true)

    req = %Req{action: :put, data: {key, value}}
    _call_or_cast(agentmap, req, opts)
  end

  @doc """
  Returns a snapshot with a key-value pairs taken from `agentmap`. Keys that are
  not in `agentmap` are ignored.

  It is a syntax sugar for

      get(agentmap, fn _ -> Process.get(:"$map") end, keys)

  ## [Option]

  Provide `!: false` to wait for execution of all the callbacks for all the
  `keys` at the moment of call. See [corresponding section](#module-[option]) for
  the details. If so, `timeout` value can be [provided](#module-timeout).

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
  @spec take(agentmap, Enumerable.t(), [option]) :: map
  def take(agentmap, keys, opts \\ [!: true]) do
    get(
      agentmap,
      fn _ ->
        Process.get(:"$map")
      end,
      keys,
      Keyword.put_new(opts, :!, true)
    )
  end

  @doc """
  Deletes the entry in the `agentmap` for a specific `key`.

  Returns *immediately*, but because of the callbacks awaiting execution,
  `keys/1` may still show some of the dropped keys. Use `cast: false` to bypass.

  ## [Option]

  Provide `!: true` to make "priority" drop calls. See [corresponding
  section](#module-[option]) for details.

  Provide `cast: false` to wait until actual delete happend. If so, `timeout`
  value can be [provided](#module-timeout).

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
  @spec delete(agentmap, key, [option | {:cast, boolean}]) :: agentmap
  def delete(agentmap, key, opts \\ [!: false, cast: true]) do
    # opts =
    #   opts
    #   |> Keyword.put_new(:cast, true)
    #   |> Keyword.put_new(:!, false)
    req = %Req{action: :delete, data: key}
    _call_or_cast(agentmap, req, opts)
  end

  @doc """
  Drops `keys` from `agentmap`.

  Returns *immediately*. Because of the callbacks awaiting for execution,
  `keys/1` may still show some of the dropped keys. Use `cast: false` to bypass.

  Also, `keys` could be dropped with:

      update(agentmap, fn _ -> :drop end, keys)
      cast(agentmap, fn _ -> :drop end, keys)
      get_and_update(agentmap, fn _ -> :pop end, keys)
      get_and_update(agentmap, fn _ -> {:ok, :drop} end, keys)

  ## [Option]

  Provide `!: true` to make "priority" drop calls. See [corresponding
  section](#module-[option]) for details.

  Provide `cast: false` to wait until actual drop happend. In this case, also,
  `timeout` can be [provided](#module-timeout).

  ## Examples

      ...> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.drop([:b, :d])
      ...> |> AgentMap.keys()
      [:a, :c]
  """
  @spec drop(agentmap, Enumerable.t(), [option | {:cast, boolean}]) :: agentmap
  def drop(agentmap, keys, opts \\ [!: false, cast: true]) do
    #    opts =
    #      opts
    #      |> Keyword.put_new(:cast, true)
    #      |> Keyword.put_new(:!, false)
    req = %Req{action: :drop, data: keys}
    _call_or_cast(agentmap, req, opts)
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

  Provide `!: false` to wait for execution of all callbacks in all the queues at
  the moment of the call. See [corresponding section](#module-[option]) for
  details.

  Also, `timeout` can be [provided](#module-timeout).

  ### Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.values()
      [1, 2, 3]
  """
  @spec values(agentmap, [option]) :: [value]
  def values(agentmap, opts \\ [!: true]) do
    opts = Keyword.put_new(opts, :!, true)
    _call(agentmap, %Req{action: :values}, opts)
  end

  @doc """
  Returns the size of the execution queue for the given `key`.

  ### Options

  Provide `!: (false) true` to count only (not) priority callbacks in the
  corresponding queue.

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
      iex> AgentMap.queue_len(am, :b)
      0
      iex> AgentMap.queue_len(am, :a, !: true)
      1
      iex> AgentMap.queue_len(am, :a, !: false)
      1
  """
  @spec queue_len(agentmap, key, [!: boolean] | []) :: non_neg_integer
  def queue_len(agentmap, key, opts \\ []) do
    opts = Keyword.take(opts, [:!])
    _call(agentmap, %Req{action: :queue_len, data: {key, opts}}, [])
  end

  @doc """
  Increment value with given `key`.

  Returns immediately, without waiting for actual increment happen, as by
  default `GenServer.cast/2` is used.

  ### Options

  Provide `step` to setup increment step.

  Provide `!: true` to make this cast call a priority. See [corresponding
  section](#module-priority-calls-true) for details.

  Provide `cast: false` to return only after increment happend. If so, `timeout`
  option can be [used](#module-timeout).

  ### Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> AgentMap.inc(am, :a)
      iex> AgentMap.get(am, :a)
      2
      iex> AgentMap.dec(am, :b)
      iex> AgentMap.get(am, :b)
      1
  """
  @spec inc(agentmap, key, [option | {:step, non_neg_integer}]) :: agentmap
  def inc(agentmap, key, opts \\ [step: 1, cast: true, !: false]) do
    opts =
      opts
      |> Keyword.put_new(:step, 1)

    # |> Keyword.put_new(:cast, true)
    # |> Keyword.put_new(:!, false)

    req = %Req{action: :inc, data: {key, opts[:step]}}
    _call_or_cast(agentmap, req, opts)
  end

  @doc """
  Decrement value with given `key`.

  Returns immediately, without waiting for actual decrement happen, as by
  default `GenServer.cast/2` is used.

  ### Options

  Provide `step` to setup decrement step.

  Provide `!: true` to make this call a priority. See [corresponding
  section](#module-priority-calls-true) for details.

  Provide `cast: false` to return only after decrement happend. If so, `timeout`
  can be [used](#module-timeout).

  ### Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> AgentMap.inc(am, :a)
      iex> AgentMap.get(am, :a)
      2
      iex> AgentMap.dec(am, :b)
      iex> AgentMap.get(am, :b)
      1
  """
  @spec dec(agentmap, key, [option | {:step, non_neg_integer}]) :: agentmap
  def dec(agentmap, key, opts \\ [step: 1, cast: true, !: false]) do
    opts =
      opts
      |> Keyword.put_new(:step, 1)

    # |> Keyword.put_new(:cast, true)
    # |> Keyword.put_new(:!, false)

    req = %Req{action: :dec, data: {key, opts[:step]}}
    _call_or_cast(agentmap, req, opts)
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

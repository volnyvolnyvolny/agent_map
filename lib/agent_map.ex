defmodule AgentMap do
  @behaviour Access

  @enforce_keys [:link]
  defstruct @enforce_keys

  alias AgentMap.{Callback, Server, Req}

  import Callback, only: :macros

  @moduledoc """
  The `AgentMap` can be seen as a stateful `Map` that parallelize operations
  made on different keys. Basically, it can be used as a cache, memoization,
  computational framework and, sometimes, as a `GenServer` replacement.

  Underneath it's a `GenServer` that holds a `Map`. If an `update/4`,
  `update!/4`, `get_and_update/4` or `cast/4` calls happend (or too many `get/4`
  calls on a single key), a special temporary process called "worker" is
  spawned. The message queue of that process became the queue of the callbacks
  for the corresponding key. An `AgentMap` respects the order in which the
  callbacks arrives and supports transactions — operations that simultaniously
  change a group of values.

  Also, the special struct `%AgentMap{}` can be created via the `new/1`
  function. This allows to use the `Enumerable` protocol and take benefit from
  the `Access` behaviour.

  ## Examples

  Create and use it like it's an ordinary `Map`:

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

  But also the `AgentMap` can be started as it's an `Agent`:

      iex> {:ok, pid} = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.put(:a, 1)
      ...> |> AgentMap.get(:a)
      1
      iex> am = AgentMap.new(pid)
      iex> am.a
      1

  Let's look at the more complicated example (memoization).

      defmodule Memo do
        use AgentMap

        def start_link() do
          AgentMap.start_link(name: __MODULE__)
        end

        def stop() do
          AgentMap.stop(__MODULE__)
        end

        @doc \"""
        If `{task, arg}` key is known — return it, else, invoke given `fun` as
        a Task, writing result under `{task, arg}`.
        \"""
        def calc(task, arg, fun) do
          AgentMap.get_and_update(__MODULE__, {task, arg}, fn
            nil ->
              res = fun.(arg)
              {res, res} # return `res` and set it as a new value

            _value ->
              :id # change nothing, return current value.
          end)
        end
      end

      defmodule Calc do
        def fib(0), do: 0
        def fib(1), do: 1

        def fib(n) when n >= 0 do
          Memo.calc(:fib, n, fn n -> fib(n - 1) + fib(n - 2) end)
        end
      end

  Also, `AgentMap` provides possibility to make transactions (operations on
  multiple keys). Let's demonstrate this on accounting demo:

      defmodule Account do
        use AgentMap

        def start_link() do
          AgentMap.start_link(name: __MODULE__)
        end

        def stop() do
          AgentMap.stop(__MODULE__)
        end

        @doc \"""
        Returns `{:ok, balance}` for account or `:error` if account
        is unknown.
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

            _ ->
              {:error} # return `:error`, while not changing value
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
            nil -> {:ok, 0} # set balance to 0, while returning :ok

            _   -> {:error} # return :error, while not changing balance
          end)
        end
      end

  ## `Enumerable` protocol and `Access` behaviour

  `%AgentMap{}` is a special struct that holds the pid of an `agentmap` process.
  `Enumerable` protocol implemented for `%AgentMap{}`, so `Enum` should work as
  expected:

      iex> AgentMap.new()
      ...> |> Enum.empty?()
      true
      iex> %{answer: 42}
      ...> |> AgentMap.new()
      ...> |> Enum.empty?()
      false

  Similarly, `AgentMap` follows `Access` behaviour, so `[]` operator could also
  be used:

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> am.a
      42

  (!) except of `put_in` operator.

  ## Options

  ### Priority calls (`!: true`)

  Most of the functions support `!: true` option to make out-of-turn
  ("priority") calls.

  On each key, no more than `5` `get/4` calls can be executed simultaneously. If
  `6`-th `get/4` call, `update!/4`, `update/4`, `cast/4` or `get_and_update/4`
  is made, a special worker process will be spawned that became the holder of
  the execution queue. It's the FIFO queue, but [selective
  receive](http://learnyousomeerlang.com/more-on-multiprocessing) can be used to
  provide the possibility for some callbacks to be executed in the order of
  preference (out-of-turn).

  For example:

      iex> import :timer
      iex> am = AgentMap.new(state: :ready)
      iex> am
      ...> |> AgentMap.cast(:state, fn _ -> sleep(50); :steady end)
      ...> |> AgentMap.cast(:state, fn _ -> sleep(50); :stop end)
      ...> |> AgentMap.cast(:state, fn _ -> sleep(50); :go end, !: true)
      ...> |> AgentMap.fetch(:state)
      {:ok, :ready}
      # — returns immediately the current value,
      # while the first `cast/3` is still in `sleep/1`.
      iex> AgentMap.get(am, :state)
      :ready
      iex> AgentMap.get(am, :state, !: true)
      :ready
      iex> am.state
      :ready
      iex> AgentMap.get(am, :state, &(&1 == :ready), !: true)
      true
      iex> AgentMap.queue_len(am, :state)
      2
      # as `cast/4` with `:steady` is already taken from queue.
      iex> AgentMap.queue_len(am, :state, !: true)
      1
      # there is no priority calls in the queue.
      iex> AgentMap.get_and_update(am, :state, & {&1}, !: true)
      :steady
      # 50 milliseconds passed.
      iex> AgentMap.get(am, :state, !: false)
      :stop
      # 150 milliseconds passed.

  Be aware that selective receive can lead to a performance issues if the
  message queue became to fat. So it is decided to turn selective receive off
  every time message queue of the worker process will have size more than `100`.
  It will be turned on again when message queue became empty.

  ## Timeout and deadlines

  A timeout is an integer greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the atom `:infinity` to wait indefinitely. By default it
  is set to the `5000 ms` = `5 sec`. For instance:

      AgentMap.get(agentmap, :key, fun)
      AgentMap.get(agentmap, :key, fun, 5000)
      AgentMap.get(agentmap, :key, fun, timeout: 5000)
      AgentMap.get(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.

  If no result is received within the specified time, the caller exits, (!) but
  the callback will remain in queue or continue it's execution!

  To change this behaviour, the special wrapper `deadline/2` is provided.

  For instance, this calls:

      AgentMap.get(agentmap, :key, deadline(fun, 5000), 5000)
      AgentMap.get(agentmap, :key, deadline(fun))

  will be deleted from execution queue if timeout happend before their execution
  starts. And this:

      AgentMap.get(agentmap, :key, deadline(
        fn _ ->
          :timer.sleep(:infinity)
        end,
        timeout: 50,
        hard: true)
      )

  will stop execution of this call after `50` milliseconds. The downside is that
  every "hard deadline" call will spawn one additional `Task` process.

  ## Safe calls

  This call:

      AgentMap.get(agentmap, :key, fn _ -> 42 / 0 end)

  will lead to the ungraceful falling of the `AgentMap` process. Sometimes it's
  not a desirable behaviour. Succefully, another wrapper, `safe/1` is provided.

      iex> AgentMap.get(agentmap, :key, safe(fn _ -> 42 / 0 end))
      {:error}

  ## Name registration

  An agentmap is bound to the same name registration rules as GenServers. Read
  more about it in the `GenServer` documentation.

  ## Hot code swapping

  `AgentMap` can have its code hot swapped live by simply passing a module,
  function, and arguments tuple to the update instruction. For example, iamine
  you have an `AgentMap` named `:sample` and you want to convert all its inner
  values from a keyword list to a map. It can be done with the following
  instruction:

      {:update, :sample, {:advanced, {Enum, :into, [%{}]}}}

  ## Other

  Similar to `Agent`, any changing state function given to the `AgentMap`
  effectively blocks execution of any other function **on the same key** until
  the request is fulfilled. So it's important to avoid use of expensive
  operations inside the agentmap.

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
  @type a_map :: agentmap

  @typedoc "The agentmap key"
  @type key :: term

  @typedoc "The agentmap value"
  @type value :: term

  @typedoc "Anonymous function, `{fun, args}` or MFA triplet"
  @type a_fun(a, r) :: (a -> r) | {(... -> r), [a | any]} | {module, atom, [a | any]}

  @typedoc "Anonymous function with zero arity, pair `{fun/length(args), args}` or corresponding MFA tuple"
  @type a_fun(r) :: (() -> r) | {(... -> r), [any]} | {module, atom, [any]}

  @typedoc "Options for :get, :get_and_update, :update and :cast methods"
  @type options :: [!: boolean, timeout: timeout] | timeout

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

  # common for start_link and start
  # separate funs from GenServer options
  defp separate(funs_and_opts) do
    {opts, funs} =
      funs_and_opts
      |> Enum.reverse()
      |> Enum.split_while(fn {k, _} ->
        k in [:name, :timeout, :debug, :spawn_opt]
      end)

    {Enum.reverse(funs), opts}
  end

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
  @spec new(Enumerable.t() | a_map) :: a_map
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
  @spec new(Enumerable.t(), (term -> {key, value})) :: a_map
  def new(enumerable, transform) do
    new(Map.new(enumerable, transform))
  end

  @doc """
  Starts an agentmap linked to the current process with the given function. This
  is often used to start the agentmap as a part of a supervision tree.

  The only argument is a keyword, elements of which is `GenServer.options` or
  pairs `{term, a_fun(any)}`, where `a_fun(any)` is a zero arity anonymous fun,
  pair `{fun, args}` or corresponding MFA-tuple.

  For each key, callback is executed as a separate `Task`.

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
  `{:ok, pid}`, where `pid` is the PID of the server. If a agentmap with the
  specified name already exists, the function returns `{:error,
  {:already_started, pid}}` with the PID of that process.

  If one of the callbacks fails, the function returns `{:error, [{key,
  init_error_reason}]}`, where `init_error_reason` is `:timeout`, `:badfun`,
  `:badarity` `:exists` or an arbitrary exception. Callback must be given in
  form of anonymous function, `{fun, args}` or MFA-tuple, or else `:badfun`
  would be returned. So you can write:

      iex> import AgentMap
      iex> {:ok,_pid} = start_link(key: fn -> Enum.empty? [:v] end)
      iex> {:ok,_} = start_link(k: {&Enum.empty?/1, [[:v]]})
      iex> {:ok,_} = start_link(k: {Enum, :empty?, [[:v]]})
      iex> {:ok,_} = start_link(k: {fn -> Enum.empty? [:v] end, []})
      iex> match?({:ok,_}, start_link(k: {& &1+1, [42]}))
      true

  But it's easy to get `{:error, :badfun}` or `{:error, :badarity}`:

      iex> AgentMap.start(key: 42)
      {:error, [key: :badfun]}
      iex> AgentMap.start(key: {fn -> Enum.empty? [] end, [:extraarg]})
      {:error, [key: :badarity]}
      # … and so on

  ## Examples

      iex> {:ok, pid} = AgentMap.start_link(key: fn -> 42 end)
      iex> AgentMap.get(pid, :key, & &1)
      42
      iex> AgentMap.get(pid, :nosuchkey, & &1)
      nil
  """
  @spec start_link([{key, a_fun(any)} | GenServer.option()]) :: on_start
  def start_link(funs_and_opts \\ [timeout: 5000]) do
    {funs, opts} = separate(funs_and_opts)
    timeout = opts[:timeout] || 5000
    # Turn off global timeout.
    opts = Keyword.put(opts, :timeout, :infinity)
    GenServer.start_link(Server, {funs, timeout}, opts)
  end

  @doc """
  Starts an `AgentMap` as unlinked process.

  See `start_link/2` for details.

  ## Examples

      iex> AgentMap.start(one: 42,
      ...>                two: fn -> :timer.sleep(150) end,
      ...>                three: fn -> :timer.sleep(:infinity) end,
      ...>                timeout: 100)
      {:error, [one: :badfun, two: :timeout, three: :timeout]}

      iex> AgentMap.start(one: :foo,
      ...>                one: :bar,
      ...>                three: fn -> :timer.sleep(:infinity) end,
      ...>                timeout: 100)
      {:error, [one: :exists]}

      iex> err = AgentMap.start(one: 76,
      ...>                      two: fn -> raise "oops" end)
      iex> {:error, [one: :badfun, two: {exception, _stacktrace}]} = err
      iex> exception
      %RuntimeError{message: "oops"}
  """
  @spec start([{key, a_fun(any)} | GenServer.option()]) :: on_start
  def start(funs_and_opts \\ [timeout: 5000]) do
    {funs, opts} = separate(funs_and_opts)
    timeout = opts[:timeout] || 5000
    # Turn off global timeout.
    opts = Keyword.put(opts, :timeout, :infinity)
    GenServer.start(Server, {funs, timeout}, opts)
  end

  defp _call(agentmap, req, opts) do
    req = struct(req, opts)
    GenServer.call(pid(agentmap), req, opts[:timeout] || 5000)
  end

  defp _cast(agentmap, %Req{} = req, opts) do
    req = struct(req, opts)
    GenServer.cast(pid(agentmap), req)
    agentmap
  end

  ##
  ## GET
  ##

  @doc """
  Takes value(s) for the given `key`(s) and invokes `fun`, passing values as the
  first argument and `nil`(s) for the values that are lost. If there are
  callbacks awaiting invocation, this call will be added to the end of the
  corresponding queues. Because the `get` calls do not change states —
  `agentmap` can and will be executed concurrently, in no more than
  `max_processes` (this could be tweaked per key, via `max_processes/2` call).

  As in the case of `update`, `get_and_update` and `cast` methods, `get` call
  has two forms:

    * single key: `get(agentmap, key, fun)`, where `fun` expected only one value
      to be passed;
    * and multiple keys (transactions): `get(agentmap, fun, [key1, key2, …])`,
      where `fun` expected to take a list of values.

  For example, compare two calls:

      AgentMap.get(Account, &Enum.sum/1, [:alice, :bob])
      AgentMap.get(Account, :alice, & &1)

  — the first one returns sum of Alice and Bob balances in one operation, while
  the second one returns amount of money Alice has.

  ## Options

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the atom `:infinity` to wait indefinitely. If no result
  is received within the specified time, the caller exits. By default it's equal
  to `5000` ms. This value could be given as `:timeout` option, or separately,
  so:

      AgentMap.get(agentmap, :key, fun)
      AgentMap.get(agentmap, :key, fun, 5000)
      AgentMap.get(agentmap, :key, fun, timeout: 5000)
      AgentMap.get(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.

  The `:!` option is used to make "priority" calls. Values could have an
  associated queue of callbacks, awaiting of execution. "Priority" version allows
  to retrive value immediately at the moment of call. If this option is
  provided, `fun` will be always executed in a separate `Task`.

  ## Special process dictionary keys

      get(agentmap, fn _ -> Process.get(:"$map") end, keys)

  which is the same as:

      get(agentmap, fn values ->
        keys
        |> Enum.zip(values)
        |> Enum.into(%{})
      end, keys)

  ## Examples

      iex> am = AgentMap.new()
      iex> AgentMap.get(am, :alice, & &1)
      nil
      iex> AgentMap.put(am, :alice, 42)
      iex> AgentMap.get(am, :alice, & &1+1)
      43
      #
      # aggregate calls:
      #
      iex> AgentMap.put(am, :bob, 43)
      iex> AgentMap.get(am, &Enum.sum/1, [:alice, :bob])
      85
      # order matters:
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
      iex> am[:key] # the same
      42
      iex> AgentMap.get(am, :key, & &1)
      43
      iex> AgentMap.get(am, :key, & &1, !: true)
      43
  """
  @spec get(a_map, a_fun([value], a), [key], options) :: a when a: var
  @spec get(a_map, key, a_fun(value, a), options) :: a when a: var

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

  @spec get(a_map, key, d) :: value | d when d: var
  @spec get(a_map, key) :: value | nil

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
  returned. Otherwise, `fun` is evaluated and its result is returned. This is
  useful if the default value is very expensive to calculate or generally
  difficult to setup and teardown again.

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
  @spec get_lazy(a_map, key, (() -> a)) :: value | a when a: var
  def get_lazy(agentmap, key, fun) do
    case fetch(agentmap, key) do
      {:ok, value} -> value
      :error -> fun.()
    end
  end

  @doc """
  `get/2` call immediately returns value for the given `key`. If there is no
  such `key`, `nil` is returned. It is a clone of `Map.get/3` function, so as
  the third argument, `default` value could be provided:

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
  Updates the `agentmap` value(s) with given `key`(s) and returns result of some
  calculation. The callback `fun` will be added to the the end of the queue for
  then given `key` (or to the begining, if `!: true` option is given). When
  invocation happens, `agentmap` takes value(s) for the given `key`(s) and
  invokes `fun`, passing values as the first argument and `nil`(s) for the
  values that are lost.

  As in the case of `get`, `update` and `cast` methods, `get_and_update` call
  has two forms:

    * single key: `get_and_update(agentmap, key, fun)`, where `fun` expected
      only one value to be passed;
    * and multiple keys (transactions): `get_and_update(agentmap, fun, [key1,
      key2, …])`, where `fun` expected to take a list of values.

  For example, compare two calls:

      AgentMap.get_and_update(Account, fn [a,b] -> {:swapped, [b,a]} end, [:alice, :bob])
      AgentMap.get_and_update(Account, :alice, & {&1, &1+1000000})

  — the first swapes balances of Alice and Bob balances, returning `:swapped`
  atom, while the second one returns current Alice balance and deposits 1000000
  dollars.

  Single key calls `fun` may return:

    * a two element tuple: `{"get" value, new value}`;
    * a one element tuple `{"get" value}`;
    * `:id` to return current value while not changing it;
    * `:pop`, similar to `Map.get_and_update/3` it returns value with given
      `key` and removes it from `agentmap`.

    * `{:chain, {key, fun}, new_value}` — to not return value, but initiate
      another `get_and_update/4` with given `key` and `fun` pair;
    * `{:chain, {fun, keys}, new_value}` — to not return value, but initiate
      transaction call `get_and_update/4` with given `fun` and `keys` pair.

  While in transaction (group/multiple keys) calls `fun` may return:

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

  All lists returned by transaction call should have length equal to the number
  of keys given.

  For ex.:

      get_and_update(agentmap, fn [a, b] ->
        if a > 10 do
          a = a-10
          b = b+10
          [{a,a}, {b,b}] # [{get, new_state}]
        else
          {{:error, "Alice does not have 10$ to give to Bob!"}, [a,b]} # {get, [new_state]}
        end
      end, [:alice, :bob])

  or:

      iex> am = AgentMap.new(alice: 42, bob: 24)
      iex> AgentMap.get_and_update(am, fn _ -> [:pop, :id] end, [:alice, :bob])
      [42, 24]
      iex> AgentMap.get(am, & &1, [:alice, :bob])
      [nil, 24]

  (!) State changing transaction (such as `get_and_update`) will block value the
  same way as a single key calls. For ex.:

      iex> AgentMap.new(alice: 42, bob: 24, chris: 0) |>
      ...> AgentMap.get_and_update(&:timer.sleep(1000) && {:slept_well, &1}, [:alice, :bob])
      :slept_well

  will block the possibility to `get_and_update`, `update`, `cast` and even
  non-priority `get` on `:alice` and `:bob` keys for 1 sec. Nonetheless values are
  always available for "priority" `get` calls and value under the key `:chris` is
  not blocked.

  Transactions are *Isolated* and *Durabled* (see, ACID model). *Atomicity* can
  be implemented inside callbacks and *Consistency* is out of question here as
  its the application level concept.

  ## Options

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the atom `:infinity` to wait indefinitely. If no result
  is received within the specified time, the caller exits. By default it's equal
  to `5000` ms. This value could be given as `:timeout` option, or separately,
  so:

      AgentMap.get_and_update(agentmap, :key, fun)
      AgentMap.get_and_update(agentmap, :key, fun, 5000)
      AgentMap.get_and_update(agentmap, :key, fun, timeout: 5000)
      AgentMap.get_and_update(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.

  The `:!` option is used to make "priority" calls. Values could have an
  associated queue of callbacks, awaiting of execution. If such queue exists,
  "priority" version will add call to the begining of the queue (via "selective
  receive").

  Be aware that: (1) anonymous function, `{fun, args}` or MFA tuple can be
  passed as a callback; (2) every value has it's own FIFO queue of callbacks
  waiting to be executed and all the queues are processed concurrently; (3) no
  value changing calls (`get_and_update`, `update` or `cast`) could be executed
  in parallel on the same value. This can be done only for `get` calls (also,
  see `max_processes/3`).

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
          a_fun(
            value,
            {a}
            | {a, value}
            | :pop
            | :id
            | {:chain, {key, callback(a)}, value}
            | {:chain, {callback_t(a), [key]}, value}
          )

  @type callback_t(a) ::
          a_fun(
            [value],
            {a}
            | {a, [value] | :drop | :id}
            | [{any} | {any, value} | :pop | :id]
            | :pop
            | :id
            | {:chain, {key, callback(a)}, value}
            | {:chain, {callback_t(a), [key]}, value}
          )

  @spec get_and_update(a_map, key, callback(a), options) :: a | value
        when a: var
  @spec get_and_update(a_map, callback_t(a), [key], options) :: a | [value]
        when a: var

  def get_and_update(agentmap, key, fun, opts \\ [])

  def get_and_update(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    req = %Req{action: :get_and_update, data: {fun, keys}}
    _call(agentmap, req, opts)
  end

  def get_and_update(agentmap, key, fun, opts) when is_fun(fun, 1) do
    req = %Req{action: :get_and_update, data: {key, fun}}
    _call(agentmap, req, opts)
  end

  ##
  ## UPDATE
  ##

  @doc """
  Updates the `agentmap` value(s) with given `key`(s) and return `:ok`. The
  callback `fun` will be added to the the end of the queue for then given `key`
  (or to the begining, if `!: true` option is given). When invocation happens,
  `agentmap` takes value(s) for the given `key`(s) and invokes `fun`, passing
  values as the first argument and `nil`(s) for the values that are lost.

  As in the case of `get`, `get_and_update` and `cast` methods, `get_and_update`
  call has two forms:

    * single key: `update(agentmap, key, fun)`, where `fun` expected only one
      value to be passed;
    * and multiple keys (transactions): `update(agentmap, fun, [key1, key2,
      …])`, where `fun` expected to take a list of values.

  For example, compare two calls:

      AgentMap.update(Account, fn [a,b] -> [b,a] end, [:alice, :bob])
      AgentMap.update(Account, :alice, & &1+1000000)

  — the first swapes balances of Alice and Bob balances, while the second one
  deposits 1000000 dollars to Alices balance.

  Single key calls `fun` must return a new value, while transaction
  (group/multiple keys) call `fun` may return:

    * a list of new values that has a length equal to the number of keys given;
    * `:id` to not change values;
    * `:drop` to delete corresponding values from `agentmap`.

  For ex.:

      iex> am = AgentMap.new(alice: 42, bob: 24, chris: 33, dunya: 51)
      iex> ^am = AgentMap.update(am, &Enum.reverse/1, [:alice, :bob])
      iex> AgentMap.get(am, & &1, [:alice, :bob])
      [24, 42]
      iex> AgentMap.update(am, fn _ -> :drop end, [:alice, :bob])
      iex> AgentMap.keys(am)
      [:chris, :dunya]
      iex> AgentMap.update(am, fn _ -> :drop end, [:chris])
      iex> AgentMap.update(am, :dunya, fn _ -> :drop end)
      iex> AgentMap.get(am, & &1, [:chris, :dunya])
      [nil, :drop]

  (!) State changing transaction (such as `get_and_update`) will block value the
  same way as a single key calls. For ex.:

      am = AgentMap.new(alice: 42, bob: 24, chris: 33)

      AgentMap.update(am, fn _ ->
        :timer.sleep(1000)
        :drop
      end, [:alice, :bob])

  will block the possibility to `get_and_update`, `update`, `cast` and even
  non-priority `get` on `:alice` and `:bob` keys for 1 sec. Nonetheless values are
  always available for "priority" `get` calls and value under the key `:chris` is
  not blocked.

  Transactions are *Isolated* and *Durabled* (see, ACID model). *Atomicity* can
  be implemented inside callbacks and *Consistency* is out of question here as
  its the application level concept.

  ## Options

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the atom `:infinity` to wait indefinitely. If no result
  is received within the specified time, the caller exits. By default it's equal
  to `5000` ms. This value could be given as `:timeout` option, or separately,
  so:[

      AgentMap.get_and_update(agentmap, :key, fun)
      AgentMap.get_and_update(agentmap, :key, fun, 5000)
      AgentMap.get_and_update(agentmap, :key, fun, timeout: 5000)
      AgentMap.get_and_update(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.

  The `:!` option is used to make "priority" calls. Values could have an
  associated queue of callbacks, awaiting of execution. If such queue exists,
  "priority" version will add call to the begining of the queue (selective receive
  used).

  Be aware that: (1) this function always returns `:ok`; (2) anonymous function,
  `{fun, args}` or MFA tuple can be passed as a callback; (3) every value has
  it's own FIFO queue of callbacks waiting to be executed and all the queues are
  processed concurrently; (3) no value changing calls (`get_and_update`,
  `update` or `cast`) could be executed in parallel on the same value. This can
  be done only for `get` calls (also, see `max_processes/3`).

  Updates the `agentmap` value(s) with given `key`(s).

  Updates agentmap state with given key. The callback `fun` will be sent to
  the `agentmap`, which will add it to the execution queue for the given key
  state. Before the invocation, the agentmap state will be passed as the first
  argument. If `agentmap` has no state with such key, `nil` will be passed to
  `fun`. The return value of callback becomes the new state of the agentmap.

  ## Examples

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

  Also, for compatibility with `Map` API (and `Map.update/4` fun),
  `update(agentmap, key, initial, fun)` call exists.

      iex> AgentMap.new(a: 42)
      ...> |> AgentMap.update(:a, :value, & &1+1)
      ...> |> AgentMap.update(:b, :value, & &1+1)
      ...> |> AgentMap.take([:a,:b])
      %{a: 43, b: :value}
  """
  # 4
  @spec update(a_map, key, a_fun(value, value), options) :: a_map
  @spec update(a_map, a_fun([value], [value]), [key], options) :: a_map
  @spec update(a_map, a_fun([value], :drop | :id), [key], options) :: a_map
  def update(agentmap, key, fun, opts \\ [!: false])

  def update(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    req = %Req{action: :update, data: {fun, keys}}
    _call(agentmap, req, opts)
  end

  def update(agentmap, key, fun, opts) when is_fun(fun, 1) do
    req = %Req{action: :update, data: {key, fun}}
    _call(agentmap, req, opts)
  end

  def update(agentmap, key, initial, fun) when is_fun(fun, 1) do
    update(agentmap, key, fn value ->
      if Process.get(:"$has_value?") do
        Callback.run(fun, [value])
      else
        initial
      end
    end)
  end

  @doc """
  Updates `key` with the given function.

  If `key` is present in `agentmap` with value `value`, `fun` is invoked with
  argument `value` and its result is used as the new value of `key`. If `key` is
  not present in `agentmap`, a `KeyError` exception is raised.

  As in the other functions, `:!` option could be provided to make "out of
  turn" calls.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> ^am = AgentMap.update!(am, :a, &(&1 * 2))
      iex> AgentMap.get(am, :a)
      2
      iex> AgentMap.update!(am, :b, &(&1 * 2))
      ** (KeyError) key :b not found
      iex> sleep = & fn _ -> :timer.sleep(&1) end
      iex> AgentMap.cast(am, :a, sleep.(50))
      iex> AgentMap.cast(am, :a, sleep.(100))
      iex> AgentMap.update!(am, :a, fn :ok -> 42 end, !: true)
      iex> AgentMap.get(am, :a)
      42
      iex> AgentMap.get(am, :a, & &1)
      :ok
  """
  def update!(agentmap, key, fun, opts \\ [!: false]) when is_fun(fun, 1) do
    callback = fn value ->
      if Process.get(:"$has_value?") do
        {:ok, Callback.run(fun, [value])}
      else
        {:error}
      end
    end

    with true <- has_key?(agentmap, key),
         :ok <- get_and_update(agentmap, key, callback, opts) do
      agentmap
    else
      _ -> raise KeyError, key: key
    end

    agentmap
  end

  @doc """
  Alters the value stored under `key` to `value`, but only if the entry `key`
  already exists in `agentmap`.

  If `key` is not present in `agentmap`, a `KeyError` exception is raised.

  ## Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> AgentMap.replace!(am, :a, 3, cast: false)
      iex> AgentMap.values(am)
      [3, 2]
      iex> AgentMap.replace!(am, :c, 2)
      ** (KeyError) key :c not found

      iex> am = AgentMap.new(a: 1)
      iex> import :timer
      iex> AgentMap.cast(am, :a, fn _ -> sleep(50); 2 end)
      iex> AgentMap.replace!(am, :a, 3)
      iex> AgentMap.get(am, )
      iex> AgentMap.cast(am, :a, fn _ -> sleep(50); 2 end)
      iex> AgentMap.cast(am, :a, fn _ -> sleep(100); 3 end)
      iex> AgentMap.replace!(am, :a, 42, !: true)
      iex> AgentMap.get(am, :a)
      42
      iex> AgentMap.get(am, :a, !: false)
      3
  """
  @spec replace!(agentmap, key, value, [!: boolean, timeout: timeout] | timeout) :: agentmap
  def replace!(agentmap, key, value, opts \\ [!: false, timeout: 5000]) do
    fun = fn _ ->
      if Process.get(:"$has_value?") do
        {:ok, value}
      else
        {:error}
      end
    end

    with true <- has_key?(agentmap, key),
         :ok <- get_and_update(agentmap, key, fun, opts) do
      agentmap
    else
      _ -> raise KeyError, key: key
    end
  end

  ##
  ## CAST
  ##

  @doc """
  Perform `cast` ("fire and forget"). Works the same as `update/4` but returns
  `agentmap` as it is **immediately**.
  """
  @spec cast(a_map, key, a_fun(value, value), !: boolean) :: a_map
  @spec cast(a_map, a_fun([value], [value]), [key], !: boolean) :: a_map
  @spec cast(a_map, a_fun([value], :drop | :id), [key], !: boolean) :: a_map
  def cast(agentmap, key, fun, opts \\ [!: false])

  def cast(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    req = %Req{action: :cast, data: {fun, keys}}
    _cast(agentmap, req, opts)
  end

  def cast(agentmap, key, fun, opts) when is_fun(fun, 1) do
    req = %Req{action: :cast, data: {key, fun}}
    _cast(agentmap, req, opts)
  end

  @doc """
  Sets the `:max_processes` value for the given `key`. Returns the old value.

  `agentmap` can execute `get` calls on the same key concurrently. `max_processes`
  option specifies number of processes per key used, minus one thread for the
  process holding the queue. By default five (5) `get` calls on the same state
  could be executed, so

      iex> import :timer
      iex> am = AgentMap.new(key: 42)
      iex> for _ <- 1..4, do: spawn(fn ->
      ...>   AgentMap.get(am, :key, fn _ -> sleep(100) end)
      ...> end)
      iex> AgentMap.get(am, :key, fn _ -> sleep(100) end)
      :ok

  will be executed in around of 100 ms, not 500. Be aware, that this call:

      import :timer

      am = AgentMap.new(key: 42)
      AgentMap.get(am, :key, fn _ -> sleep(100) end)
      AgentMap.cast(am, :key, fn _ -> sleep(100) end)
      AgentMap.cast(am, :key, fn _ -> sleep(100) end)

  will be executed in around of 200 ms because `agentmap` can parallelize any
  sequence of `get/3` calls ending with `get_and_update/3`, `update/3` or
  `cast/3`.

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
    _call(agentmap, %Req{action: :max_processes, data: {key, value}, !: true}, [])
  end

  @doc """
  Fetches the value for a specific `key` in the given `agentmap`.

  If `agentmap` contains the given `key` with value value, then `{:ok, value}`
  is returned. If it's doesn’t contain `key` — `:error` is returned.

  Returns value *immediately*, unless `!: false` option is given.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.fetch(am, :a)
      {:ok, 1}
      iex> AgentMap.fetch(am, :b)
      :error

  ## Options

  `!: false` option can be provided, putting this call at the end of the
  execution queue. See [corresponding docs section](#module-options). In this
  case `timeout` could be [provided](#module-timeout). Most likely, you do not
  need this option.

      iex> import :timer
      iex> am = AgentMap.new()
      iex> AgentMap.cast(am, :b, fn _ -> sleep(50); 42 end)
      iex> AgentMap.fetch(am, :b)
      :error
      iex> AgentMap.fetch(am, :b, !: false)
      {:ok, 42}
  """
  @spec fetch(agentmap, key, options) :: {:ok, value} | :error
  def fetch(agentmap, key, opts \\ [!: true]) do
    if Keyword.get(opts, :!, true) do
      req = struct(%Req{action: :fetch, data: key}, opts)
      _call(agentmap, req, opts)
    else
      get(agentmap, key, fn v ->
        hv? = Process.get(:"$has_value?")
        (hv? && {:ok, v}) || :error
      end)
    end
  end

  @doc """
  Fetches the value for a specific `key` in the given `agentmap`, erroring out
  if `agentmap` doesn't contain `key`. If `agentmap` contains the given `key`,
  the corresponding value is returned. If `agentmap` doesn't contain `key`, a
  `KeyError` exception is raised.

  Returns value *immediately*, unless `!: false` option is given.

  ## Options

  `!: false` option can be provided, putting this call at the end of the
  execution queue. See [corresponding docs section](#module-options). In this
  case `timeout` could be [provided](#module-timeout). Most likely, you do not
  need this option.

      iex> import :timer
      iex> am = AgentMap.new()
      iex> AgentMap.cast(am, :b, fn _ -> sleep(50); 42 end)
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
      {:ok, value} -> value
      :error -> raise KeyError, key: key
    end
  end

  @doc """
  *Immediately* returns whether the given `key` exists in the given `agentmap`.

  ## Options

  `!: false` option can be provided, putting this call at the end of the
  execution queue. See [corresponding docs section](#module-options). In this
  case `timeout` could be [provided](#module-timeout). Most likely, you do not
  need this option.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> AgentMap.has_key?(am, :a)
      true
      iex> AgentMap.has_key?(am, :b)
      false
  """
  @spec has_key?(agentmap, key, options) :: boolean
  def has_key?(agentmap, key, opts \\ [!: true]) do
    match?({:ok, _}, fetch(agentmap, key, opts))
  end

  @doc """
  Removes and returns the value associated with `key` in `agentmap`. If there is
  no such `key` in `agentmap`, `default` is returned (`nil`).

  ## Options

  `!: false` option can be provided, adding `pop` call to the end of the
  execution queue. See [corresponding docs section](#module-options).

  Most likely, you do not need this option.

  Also, `timeout` could be [provided](#module-timeout)

  ## Analogs

  Analogous behaviour can be achieved with

      get_and_update(agentmap, key, fn _ -> :pop end)
      get_and_update(agentmap, fn [v] -> {v, :drop} end, [key])

  and

      get_and_update(agentmap, key, fn v ->
        hv? = Process.get(:"$has_value?")
        hv? && :pop || {default}
      end)

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
  @spec pop(agentmap, key, any, options) :: value | any
  def pop(agentmap, key, default \\ nil, opts \\ [!: true]) do
    _call(agentmap, %Req{action: :pop, data: {key, default}}, opts)
  end

  @doc """
  Puts the given `value` under the `key` in the `agentmap`.

  Returns *immediately*, but you can provide `cast: false` to make this call
  wait until actual put is made.

  ## Options

  By default this call is ["priority"](#module-options), but `!: false` option can
  be provided to add `put` call to the end of the execution queue. Most likely,
  you do not need this.

  `cast: false` option make this call wait until put is made. By default,
  `GenServer.cast/2` is used. If cast is turned off, `timeout` could be
  [configured](#module-timeout).

  ## Analogs

  The same could be made with:

      update(agentmap, key, fn _ -> value end, !: true)
      cast(agentmap, key, fn _ -> value end, !: true)
      get_and_update(agentmap, key, fn old -> {old, value} end, !: true)

  or:

      update(agentmap, fn _ -> [value] end, [key], !: true)
      cast(agentmap, fn _ -> [value] end, [key], !: true)
      get_and_update(agentmap, key, fn [old] -> {old, [value]} end, !: true)

  But `put/4` works a little bit faster and does not create unnecessarily `Task`
  processes.

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
  @spec put(agentmap, key, value, !: boolean, cast: boolean, timeout: timeout) :: agentmap
  def put(agentmap, key, value, opts \\ [!: true, cast: true]) do
    req = %Req{action: :put, data: {key, value}}

    if Keyword.get(opts, :cast, true) do
      _cast(agentmap, req, opts)
    else
      _call(agentmap, req, opts)
    end
  end

  @doc """
  Returns a `Map` with key-value pairs taken from `agentmap`. Keys that are not
  in `agentmap` are ignored.

  ## Options

  By default, **immediately** returns the snapshot of the `agentmap` (it's
  part). But if `!: false` option is given this call will wait for execution of
  all the callbacks for all the `keys` at the moment of call. See [corresponding
  section](#module-options) for details.

  Also, `timeout` can be [provided](#module-timeout).

  ## Analogs

      take(agentmap, keys, !: false)

  is a syntax sugar for

      get(agentmap, fn _ -> Process.get(:"$map") end, keys)

  see `get/4`.

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

  But:

      iex> import :timer
      iex> AgentMap.new(a: 1)
      ...> |> AgentMap.cast(fn _ -> sleep(100); 42 end)
      ...> |> AgentMap.take([:a], !: false)
      %{a: 42}
  """
  @spec take(agentmap, Enumerable.t(), options) :: map
  def take(agentmap, keys, opts \\ [!: true]) do
    if Keyword.get(opts, :!, true) do
      map = _call(agentmap, %Req{action: :take, data: keys}, opts)

      Enum.reduce(Map.keys(map), %{}, fn k, map ->
        case Req.fetch(map, k) do
          {:ok, v} ->
            put_in(map[k], v)

          _ ->
            map
        end
      end)
    else
      get(agentmap, fn _ -> Process.get(:"$map") end, keys)
    end
  end

  @doc """
  Deletes the entry in `agentmap` for a specific `key`.

  Returns *immediately*, but `keys/1` may still show dropped key because of the
  callbacks waiting for execution. You can provide `cast: false` to make this
  call wait until actual delete is made.

  ## Options

  `!: true` option can be provided to make "priority" drop calls. See
  [corresponding section](#module-options) for details.

  `cast: false` option make this call wait until delete is made. By default,
  `GenServer.cast/2` is used. If cast is turned off, `timeout` could be
  [provided](#module-timeout).

  ## Analogs

  Also, key could be dropped with

      get_and_update(agentmap, key, fn _ -> :pop end) # also returns it

  and even

      update(agentmap, fn _ -> :drop end, [key])
      cast(agentmap, fn _ -> :drop end, [key])
      get_and_update(agentmap, fn _ -> :pop end, [key])
      get_and_update(agentmap, fn _ -> {:ok, :drop} end, [key])

  There is only one imaginable case to prefer this. You can wrap callback using
  `timeout/1` with `hard: true` option given, to remove delete call from
  execution queue if timeout happend:

      cast(agentmap, timeout(fn _ -> :drop end, 5000, hard: true), [key])

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
  @spec delete(agentmap, key, !: boolean, cast: boolean, timeout: timeout) :: agentmap
  def delete(agentmap, key, opts \\ [!: false, cast: true]) do
    req = %Req{action: :delete, data: key}

    if Keyword.get(opts, :cast, true) do
      _cast(agentmap, req, opts)
    else
      _call(agentmap, req, opts)
    end
  end

  @doc """
  Drops the given `keys` from `agentmap`.

  Returns *immediately*, but `keys/1` may still show some of the dropped keys
  because of the callbacks waiting for execution. You can provide `cast: false`
  to make this call wait until actual drop is made.

  ## Options

  `!: true` option can be provided to make "priority" drop calls. See
  [corresponding section](#module-options) for details.

  `cast: false` option make this call wait until drop is made. As it was sad, by
  default, `GenServer.cast/2` is used to make this call. If cast is turned off,
  `timeout` could be [provided](#module-timeout).

  ## Analogs

  Also, keys could be dropped with:

      update(agentmap, fn _ -> :drop end, keys)
      cast(agentmap, fn _ -> :drop end, keys)
      get_and_update(agentmap, fn _ -> :pop end, keys)
      get_and_update(agentmap, fn _ -> {:ok, :drop} end, keys)

  So you stop execution of all queues until all values are dropped.

  ## Examples

      ...> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.drop([:b, :d])
      ...> |> AgentMap.keys()
      [:a, :c]
  """
  @spec drop(agentmap, Enumerable.t(), !: boolean, cast: boolean, timeout: timeout) :: agentmap
  def drop(agentmap, keys, opts \\ [!: false, cast: true]) do
    req = %Req{action: :drop, data: keys}

    if Keyword.get(opts, :cast, true) do
      _cast(agentmap, req, opts)
    else
      _call(agentmap, req, opts)
    end
  end

  @doc """
  Returns all the keys of given `agentmap`.

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

  `!: false` can be given to wait for execution of all callbacks in all the
  queues at the moment of call. This can be helpful if your `agentmap` has a
  small set of keys (for ex. it's fixed). See [corresponding
  section](#module-options) for details.

  Also, `timeout` can be [provided](#module-timeout).

  ### Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> AgentMap.values()
      [1, 2, 3]
  """
  @spec values(agentmap, options) :: [value]
  def values(agentmap, opts \\ [!: true]) do
    if Keyword.get(opts, :!, true) do
      map = _call(agentmap, %Req{action: :take_all}, opts)

      for k <- Map.keys(map) do
        case Req.fetch(map, k) do
          {:ok, v} ->
            [v]

          _err ->
            []
        end
      end
      |> List.flatten()
    else
      _call(agentmap, %Req{action: :values}, opts)
    end
  end

  @doc """
  Number of callbacks waiting for execution on given `key`.

  ### Options

  `!: true` or `!: false` options could be provided to count priority and not
  priority callbacks respectively in the corresponding queue. See [corresponding
  section](#module-options) for details.

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
    _call(agentmap, %Req{action: :queue_len, data: {key, opts}}, [])
  end

  @doc """
  Increment value with given `key`. Returns **immediately** as it uses
  `GenServer.cast/2` internally.

  ### Options

  Provide `!: true` to make this cast call a priority. See [corresponding
  section](#module-options) for details.

  Provide `cast: false` to return only after increment happend. If so, `timeout`
  can be [given](#module-timeout).

  Provide `step` to setup increment step.

  ### Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> AgentMap.inc(am, :a)
      iex> AgentMap.get(am, :a)
      2
      iex> AgentMap.dec(am, :b)
      iex> AgentMap.get(am, :b)
      1
  """
  @spec inc(agentmap, key, !: boolean, cast: boolean, timeout: timeout, step: non_neg_integer) ::
          agentmap
  def inc(agentmap, key, opts \\ [!: false, cast: true, step: 1]) do
    step = opts[:step] || 1

    req = %Req{action: :inc, data: {key, step}}

    if Keyword.get(opts, :cast, true) do
      _cast(agentmap, req, opts)
    else
      case _call(agentmap, req, opts) do
        {:error, e} ->
          raise e

        :ok ->
          agentmap
      end
    end
  end

  @doc """
  Decrement value with given `key`. Returns **immediately** as it uses
  `GenServer.cast/2` internally.

  ### Options

  Provide `!: true` to make this call a priority. See [corresponding
  section](#module-options) for details.

  Provide `cast: false` to return only after decrement happend. If so, `timeout`
  can be [given](#module-timeout).

  Provide `step` to setup decrement step.

  ### Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> AgentMap.inc(am, :a)
      iex> AgentMap.get(am, :a)
      2
      iex> AgentMap.dec(am, :b)
      iex> AgentMap.get(am, :b)
      1
  """
  @spec dec(agentmap, key, !: boolean, cast: boolean, step: non_neg_integer) :: agentmap
  def dec(agentmap, key, opts \\ [!: false, cast: false, step: 1]) do
    step = opts[:step] || 1

    req = %Req{action: :inc, data: {key, -step}}

    if Keyword.get(opts, :cast, true) do
      _cast(agentmap, req, opts)
    else
      _call(agentmap, req, opts)
    end
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

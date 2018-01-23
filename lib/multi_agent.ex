defmodule MultiAgent do

  @moduledoc """
  MultiAgent is a simple abstraction around **group** of states. Often in Elixir
  there is a need to share or store group of states that must be accessed from
  different processes or by the same process at different points in time. There
  are two main solutions: (1) use a group of `Agent`s; or (2) a
  `GenServer`/`Agent` that hold states in some key-value storage
  (ETS/`Map`/process dictionary) and provides concurrent access for different
  states. The `MultiAgent` module follows the latter approach. It stores states
  in a number of processed that executes user requests. Module provides a basic
  server implementation that allows states to be retrieved and updated via an
  API similar to the one of `Agent` and `Map` modules.

  ## Examples

  For example, let us manage tasks and projects. Each task can be in `:added`,
  `:started` or `:done` states. This is easy to do with a `MultiAgent`:

      defmodule TasksServer do
        use MultiAgent

        def start_link do
          MultiAgent.start_link( name: __MODULE__)
        end

        @doc "Add new task"
        def add( task, project) do
          MultiAgent.init(__MODULE__, {task, project}, fn -> :added end)
        end

        @doc "Returns state of given task"
        def state( task, project) do
          MultiAgent.get(__MODULE__, {task, project}, & &1)
        end

        @doc "Returns list of all tasks for project"
        def list( project) do
          MultiAgent.keys(__MODULE__)
        end

        @doc "Returns list of tasks for project in given state"
        def list( project, state: state) do
          MultiAgent.reduce(__MODULE__, [], & if &2 == state, do: [&1], else: [])
          |> List.flatten()
        end

        @doc "Updates task for project"
        def update( task, project, new_state) do
          MultiAgent.update(__MODULE__, {task, project}, fn _ -> new_state end)
        end

        @doc "Deletes given task for project, returning state"
        def take( task, project) do
          MultiAgent.get_and_update(__MODULE__, {task, project}, fn _ -> :pop end)
        end
      end

  As in `Agent` module case, `MultiAgent` provide a segregation between the
  client and server APIs (similar to GenServers). In particular, any anonymous
  functions given to the `MultiAgent` is executed inside the multiagent (the
  server) and effectively block execution of any other function **on the same
  state** until the request is fulfilled. So it's important to avoid use of
  expensive operations inside the multiagent (see, `Agent`). See corresponding
  `Agent` docs section.

  Finally note that `use MultiAgent` defines a `child_spec/1` function, allowing
  the defined module to be put under a supervision tree. The generated
  `child_spec/1` can be customized with the following options:

    * `:id` - the child specification id, defauts to the current module
    * `:start` - how to start the child process (defaults to calling `__MODULE__.start_link/1`)
    * `:restart` - when the child should be restarted, defaults to `:permanent`
    * `:shutdown` - how to shut down the child

  For example:

      use MultiAgent, restart: :transient, shutdown: 10_000

  See the `Supervisor` docs for more information.

  ## Name registration

  An multiagent is bound to the same name registration rules as GenServers. Read
  more about it in the `GenServer` documentation.

  ## A word on distributed agents/multiagents

  See corresponding `Agent` module section.

  ## Hot code swapping

  A multiagent can have its code hot swapped live by simply passing a module,
  function, and arguments tuple to the update instruction. For example, imagine
  you have a multiagent named `:sample` and you want to convert all its inner
  states from a keyword list to a map. It can be done with the following
  instruction:

      {:update, :sample, {:advanced, {Enum, :into, [%{}]}}}

  The multiagent's states will be added to the given list of arguments
  (`[%{}]`) as the first argument.

  # Using `Enum` module and `[]`-access operator

  `p_enum` package implements `Enumerable` protocol for processes. After it is
  added to your deps, `Enum` could be used to interact with given multiagent:

      > {:ok, multiagent} = MultiAgent.start()
      > Enum.empty? multiagent
      true
      > MultiAgent.init( multiagent, :key, fn -> 42 end)
      42
      > Enum.empty? multiagent
      false

  Similarly, `p_access` package implements `Access` protocol, so adding it
  to your deps gives a nice syntax sugar:

      > {:ok, multiagent} = MultiAgent.start( key: fn -> 42 end)
      > multiagent[:key]
      42
      > multiagent[:errorkey]
      nil
  """

  @typedoc "Return values of `start*` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid} | term}

  @typedoc "The multiagent name"
  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "The multiagent reference"
  @type multiagent :: pid | {atom, node} | name

  @typedoc "The multiagent state key"
  @type key :: term

  @typedoc "The multiagent state"
  @type state :: term

  @typedoc "Anonymous function, `{fun, args}` or MFA triplet"
  @type fun_arg( a, r) :: (a -> r) | {(... -> r), [a | any]} | {module, atom, [a | any]}

  @typedoc "Anonymous function with zero arity, pair `{fun/length( args), args}` or corresponding MFA tuple"
  @type fun_arg( r) :: (() -> r) | {(... -> r), [any]} | {module, atom, [any]}


  alias MultiAgent.Callback


  @doc false
  def child_spec( tuples) do
    %{
      id: MultiAgent,
      start: {MultiAgent, :start_link, [tuples]}
    }
  end


  @doc false
  defmacro __using__( opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      spec = [
        id: opts[:id] || __MODULE__,
        start: Macro.escape( opts[:start]) || quote( do: {__MODULE__, :start_link, [funs]}),
        restart: opts[:restart] || :permanent,
        shutdown: opts[:shutdown] || 5000,
        type: :worker
      ]

      @doc false
      def child_spec( funs) do
        %{unquote_splicing( spec)}
      end

      defoverridable child_spec: 1
    end
  end



  # common for start_link and start
  defp separate( funs_and_opts) do
    {opts, funs} = Enum.reverse( funs_and_opts)
                   |> Enum.split_while( fn {_,v} -> not Callback.valid?( v) end)

    {Enum.reverse( funs), opts}
  end


  defp start( mf, funs_and_opts) do
    {funs, opts} = separate( funs_and_opts)

    opts = opts |> Keyword.put_new(:timeout, 5000)
                |> Keyword.put_new(:async, true)

    apply( mf, [MultiAgent.Server, {funs, opts[:async], opts[:timeout]}, opts])
  end


  @doc """
  Starts a multiagent linked to the current process with the given function.
  This is often used to start the multiagent as part of a supervision tree.

  The first argument is a list of pairs `{term, fun_arg}` (keyword, in
  particular). The second element of each pair is an anonymous function, `{fun,
  args}` or MFA-tuple with zero num of arguments.

  For each key, callback is executed in a separate process. Provide `async:
  false` option to execute callbacks sequentially in the order they were given.

  ## Options

  The `:name` option is used for registration as described in the module
  documentation.

  If the `:timeout` option is present, the multiagent is allowed to spend at
  most the given number of milliseconds on the whole process of initialization
  or it will be terminated and the start function will return `{:error,
  :timeout}`.

  If the `:debug` option is present, the corresponding function in the
  [`:sys` module](http://www.erlang.org/doc/man/sys.html) will be invoked.

  If the `:spawn_opt` option is present, its value will be passed as options
  to the underlying process as in `Process.spawn/4`.

  If the `:async` option is present and its value is true, every callback is
  executed as a `Task`.

  ## Return values

  If the server is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a multiagent with the
  specified name already exists, the function returns `{:error,
  {:already_started, pid}}` with the PID of that process.

  If one of the callbacks fails, the function returns `{:error, [{key,
  init_error_reason}]}`, where `init_error_reason` is `:timeout`,
  `:cannot_call`, `already_exists` or arbitrary exception. Callback must be
  given in form of anonymous function, `{fun, args}` or MFA-tuple, or else
  `:cannot_call` would be returned. So this are allowed:

      fn -> Enum.empty? [:a, :b] end
      {&Enum.empty?/1, [[:a, :b]]}
      {Enum, :empty?, [[:a, :b]]}
      {fn -> Enum.empty? [:a, :b] end, []}
      {& &1+1, [42]}

  and this are not:

      42
      {fn -> Enum.empty? [1,2,3] end, [:extraarg]}
      … and so on

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link( key: fn -> 42 end)
      iex> MultiAgent.get( pid, :key, & &1)
      42
      iex> MultiAgent.get( pid, :nosuchkey, & &1)
      nil
  """
  @spec start_link( [{term, fun_arg( any)} | GenServer.option | {:async, boolean}]) :: on_start
  def start_link( funs_and_opts \\ [timeout: 5000, async: true]) do
    start( &GenServer.start_link/3, funs_and_opts)
  end

  @doc """
  Starts a multiagent process without links (outside of a supervision tree).

  See `start_link/2` for details.

  ## Examples

      iex> MultiAgent.start( key1: 42,
      ...>                   key2: fn -> :timer.sleep(150) end,
      ...>                   key3: fn -> :timer.sleep(:infinity) end,
      ...>                   timeout: 100)
      {:error, [key1: :cannot_call, key2: :timeout, key3: :timeout]}

      iex> MultiAgent.start( key1: :foo,
      ...>                   key1: :bar,
      ...>                   key2: fn -> :timer.sleep(:infinity) end,
      ...>                   timeout: 100)
      {:error, [key1: :already_exists]}

      iex> err = MultiAgent.start( key1: 76, key2: fn -> raise "oops" end)
      iex> {:error, [key1: :cannot_call, key2: {exception, _stacktrace}]} = err
      iex> exception
      %RuntimeError{ message: "oops"}

      # but:
      iex> MultiAgent.start( key1: fn -> :timer.sleep(:infinity) end,
      ...>                   key2: :errorkey,
      ...>                   timeout: 100,
      ...>                   async: false)
      {:error, :timeout}
  """
  @spec start( [{term, fun_arg( any)} | GenServer.option | {:async, boolean}]) :: on_start
  def start( funs_and_opts \\ [timeout: 5000, async: true]) do
    start( &GenServer.start/3, funs_and_opts)
  end


  @doc """
  Initialize a multiagent state via the given anonymous function with zero
  arity, `{fun/length(args), args}` or corresponding MFA triplet. The callback
  is sent to the `multiagent` which invokes it in `GenServer` call.

  Its return value is used as the multiagent state with given key. Note that
  `init/4` does not return until the given callback has returned.

  State may also be added via `update/4` or `get_and_update/4` functions:

      update( multiagent, :key, fn nil -> :state end)
      update( multiagent, fn _ -> [:s1, :s2] end, [:key1, :key2])

  ## Options

  `:timeout` option specifies an integer greater than zero which defines how
  long (in milliseconds) multiagent is allowed to spend on initialization before
  init task will be `Task.shutdown(…, :brutal_kill)`ed and this function will
  return `{:error, :timeout}`. Also, the atom `:infinity` can be provided to
  make multiagent wait infinitely.

  `:callexpired` option specifies should multiagent execute functions that are
  expired. This happend when caller timeout is took place before function
  execution.

  `:async` option specifies should multiagent execute `get` calls on the same
  key in parallel. By default it is set to true, so

      sleep100ms = fn _ -> :timer.sleep(100) end
      List.duplicate( fn -> MultiAgent.get( multiagent, :k, sleep100ms) end, 5)
      |> Enum.map( &Task.async/1)
      |> Enum.map( &Task.await/1)

  will be executed in around of 100 ms, not 500. Be aware, that this call:

      Task.start( fn -> get( multiagent, :k, sleep100ms) end)
      get_and_update( multiagent, :k, sleep100ms)
      get_and_update( multiagent, :k, sleep100ms)

  will be executed in around of 200 ms because `multiagent` can parallelize any
  sequence of `get/4` calls ending with `get_and_update/4` or `update/4` calls.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link()
      iex> MultiAgent.get( pid, :k, & &1)
      nil
      iex> MultiAgent.init( pid, :k, fn -> 42 end)
      {:ok, 42}
      iex> MultiAgent.get( pid, :k, & &1)
      42
      iex> MultiAgent.init( pid, :k, fn -> 43 end)
      {:error, {:k, :already_exists}}
      iex> MultiAgent.init( pid, :_, fn -> :timer.sleep(300) end, timeout: 200)
      {:error, :timeout}
      iex> MultiAgent.init( pid, :k, fn -> :timer.sleep(300) end, timeout: 200)
      {:error, {:k, :already_exists}}
      iex> MultiAgent.init( pid, :k2, fn -> 42 end, callexpired: false)
      {:ok, 42}
      iex> MultiAgent.cast( pid, :k2, & :timer.sleep(100) && &1) #blocks for 100 ms
      iex> MultiAgent.update( pid, :k, fn _ -> 0 end, timeout: 50)
      {:error, :timeout}
      iex> MultiAgent.get( pid, :k, & &1) #update was not happend
      42
  """
  @spec init( multiagent, key, fun_arg( a), keyword)
        :: {:ok, a}
         | {:error, :timeout}
         | {:error, {key, :already_exists | :cannot_execute | any}} when a: var
  def init( multiagent, key, fun, opts \\ [timeout: 5000, callexpired: true]) do
    GenServer.call( multiagent,
                    {:init, key, fun, opts[:callexpired] || false},
                    opts[:timeout] || 5000)
  end


  # batch processing
  defp batch_call( multiagent, funs_and_opts, atom) do
    {funs, opts} = separate( funs_and_opts)

    keys = Keyword.keys( funs)
    funs = Keyword.values( funs)

    prun = fn {fun, state} ->
      Task.start_link( Callback.run( fun, [state]))
    end

    GenServer.call( multiagent,
                    {atom, & Enum.zip( funs, &1) |> Enum.map( prun), keys},
                    opts[:timeout] || 5000)
  end


  @doc """
  Gets the multiagent state with given key. The callback `fun` will be sent to
  the `multiagent`, which will add it to the execution queue for the given key.
  Before the invocation, the multiagent state will be passed as the first
  argument. If `multiagent` has no state with such key, `nil` will be passed to
  `fun`. The result of the `fun` invocation is returned from this function.

  Also, list of keys could be passed to make aggregate function calls:

      get( accounts, &Enum.sum/1, [:alice, :bob])

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the multiagent executes the callback and
  returns the result value, or the atom `:infinity` to wait indefinitely. If no
  result is received within the specified time, the function call fails and the
  caller exits. If this happened but callback is so far in the queue it will
  never be executed.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link()
      iex> MultiAgent.get( pid, :key, & &1)
      nil
      iex> MultiAgent.init( pid, :key, fn -> 42 end)
      42
      iex> MultiAgent.get( pid, :key, & &1)
      42
      iex> MultiAgent.get( pid, :key, & &1+1)
      43
      #
      # aggregate calls:
      #
      iex> MultiAgent.init( pid, :key2, fn -> 43 end)
      43
      iex> MultiAgent.get( pid, &Enum.sum/1, [:key, :key2])
      85
      # order matters:
      iex> MultiAgent.get( pid, {&Enum.reduce/3, [0, &-/2]}, [:key, :key2])
      1
      iex> MultiAgent.get( pid, {&Enum.reduce/3, [0, &-/2]}, [:key2, :key])
      -1
  """
  def get( multiagent, _, _, timeout \\ 5000)

  @spec get( multiagent, fun_arg( [state], a), [key], timeout) :: a when a: var
  def get( multiagent, fun, keys, timeout) when is_list( keys) do
    GenServer.call( multiagent, {:get, fun, keys}, timeout)
  end

  @spec get( multiagent, key, fun_arg( state, a), timeout) :: a when a: var
  def get( multiagent, key, fun, timeout) do
    GenServer.call( multiagent, {:get, key, fun}, timeout)
  end

  @doc """
  Version of `get/4` for batch processing. Be aware, that states for all keys
  are locked until callback is executed (see `get_and_update/4` for details).

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link()
      iex> MultiAgent.get( pid, alice: & &1, bob: & &1)
      [nil, nil]
      iex> MultiAgent.update( pid, alice: fn nil -> 42 end,
      ...>                         bob:   fn nil -> 24 end)
      :ok
      iex> MultiAgent.get( pid, alice: & &1, bob: & &1)
      [42, 24]
      iex> MultiAgent.update( pid, alice: & &1-10, bob: & &1+10)
      iex> MultiAgent.get( pid, alice: & &1, bob: & &1)
      [32, 34]
  """
  @spec get( multiagent, [{key, fun_arg( state, any)} | {:timeout, timeout}]) :: [any]
  def get( multiagent, funs_and_timeout) do
    batch_call( multiagent, funs_and_timeout, :get)
  end


  @doc """
  Works as `get/4`, but executes callback asynchronously, as a separate `Task`.
  Every state has an associated queue of calls to be made on it. Using `get!/4`
  the state with given key can be retrived immediately, "out of queue turn".

  See `get/4` for the details.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link( key: fn -> 42 end)
      iex> MultiAgent.cast( pid, :key, fn _ -> :timer.sleep( 100); 43 end)
      iex> MultiAgent.get!( pid, :key, & &1)
      42
      iex> MultiAgent.get( pid, :key, & &1)
      43
      iex> MultiAgent.get!( pid, :key, & &1)
      43
  """
  def get!( multiagent, _, _, timeout \\ 5000)

  @spec get!( multiagent, fun_arg( [state], a), [key], timeout) :: a when a: var
  def get!( multiagent, fun, keys, timeout) when is_list( keys) do
    GenServer.call( multiagent, {:get!, fun, keys}, timeout)
  end

  @spec get!( multiagent, key, fun_arg( state, a), timeout) :: a when a: any
  def get!( multiagent, key, fun, timeout) do
    GenServer.call( multiagent, {:get!, key, fun}, timeout)
  end


  @doc """
  Gets and updates the multiagent state with given key in one operation. The
  callback `fun` will be sent to the `multiagent`, which will add it to the
  execution queue for then given key. Before the invocation, the multiagent
  state will be passed as the first argument. If `multiagent` has no state with
  such key, `nil` will be passed to the `fun`. The function must return a tuple
  with two elements, the first being the value to return (that is, the "get"
  value) and the second one being the new state.

  Callback may also return `:pop`. Similar to `Map.get_and_update/3` it returns
  state with given key and removes it from `multiagent`.

  Be aware that: (1) as a callback can be passed anonymous function, `{fun,
  args}` or MFA tuple; (2) every state has it's own FIFO queue of callbacks and
  all the queues are processed asynchronously.

  ## Transaction calls

  Transaction call could be made by

  (1) passing list of keys and callback that takes list of states with given
  keys and returns list of get values and new states:

      get_and_update( multiagent, fn [a, b] ->
        if a > 10 do
          a = a-10
          b = b+10
          [{a,a}, {b,b}] # [{get, new_state}]
        else
          {{:error, "Alice does not have 10$ to give to Bob!"}, [a,b]} # {get, [new_state]}
        end
      end, [:alice, :bob])

  Please notice that in this case keys and fun arguments are swaped (list must
  be given as the third argument). This follows from fact that `multiagent` do
  not impose any restriction on the key type: anything can be a key in a
  `multiagent`, even a list. So it could not be detected if its a key or a list
  of keys.

  Callback may return list of `{get, new_state} | :id | :pop`. Keys for which
  `:pop` atom is returned will be removed from `multiagent`. `:id` will not
  change state, returning it as it is now:

      > get_and_update( pid, fn _ -> [:pop, :id] end, [:alice, :bob])
      [alice_state, bob_state]
      > get( pid, & &1, [:alice, :bob]) # no more :alice
      [nil, bob_state]

  Also, as in the error statement of previous example, callback may return pair
  `{get, [new_state]}`. This way aggregated value will be returned and all the
  corresponding states will be updated.

  Also, callback may return `:pop` to remove all given keys.

  (2) passing list of `{key, callback}` pairs. This is for batch processing. Be
  aware, that every callback will run in parallel and execution queue for all
  the keys are locked (see next section).

  (!) Passing key list will lock all the correspondings states queues until
  callback is executed. So, for example,

      get( multiagent, fn _ -> :timer.sleep( 1000) end, [:alice, :bob])

  will block the possibility to update or get `:alice` and `:bob` states for 1
  sec. Nonetheless state with given key is still available for `get!/4`.

  Transactions provided by `get_and_update/4`, `get_and_update/2` and `update/4`
  and `update/2` are *Isolated* and *Durabled* (see, ACID model). *Atomicity*
  can be implemented inside callbacks and *Consistency* is out of question here
  as its the application level concept.

  ## Timeout

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the multiagent executes the function and
  returns the result value, or the atom `:infinity` to wait indefinitely. If no
  result is received within the specified time, the function call fails and the
  caller exits. If this happened but callback is so far in the queue, and in
  `init/4` call `:callexpired` flag is set to true, it will still be executed.

  ## Examples

      iex> import MultiAgent
      iex> {:ok, pid} = start_link( k1: fn -> 22 end,
      ...>                          k2: fn -> 24 end,
      ...>                          k3: fn -> 42 end,
      ...>                          k4: fn -> 44 end)
      iex> get_and_update( pid, :k1, & {&1, &1 + 1})
      22
      iex> get( pid, :k1, & &1)
      23
      #
      iex> get_and_update( pid, :k3, fn _ -> :pop end)
      42
      iex> get( pid, :k3, & &1)
      nil
      #
      # transaction calls:
      #
      iex> get_and_update( pid, fn [s1, s2] -> [{s1, s2}, {s2, s1}]} end,
      ...>                      [:k1, :k2])
      [23, 24]
      iex> get( pid, & &1, [:k1, :k2])
      [24, 23]
      #
      iex> get_and_update( pid, fn _ -> :pop, [:k2])
      [42]
      iex> get( pid, & &1, [:k1, :k2, :k3, :k4])
      [24, nil, nil, 44]
      #
      iex> get_and_update( pid, fn _ -> [:id, {nil, :_}, {:_, nil}, :pop] end,
      ...>                      [:k1, :k2, :k3, :k4])
      [24, nil, :_, 44]
      iex> get( pid, & &1, [:k1, :k2, :k3, :k4])
      [24, :_, nil, nil]
  """
  def get_and_update( multiagent, fun, keys, timeout \\ 5000)

  @spec get_and_update( multiagent,
                        fun_arg([state], [{any, state} | :pop | :id]),
                        [key],
                        timeout)
        :: [any | state]
  @spec get_and_update( multiagent, fun_arg([state], :pop), [key], timeout)
        :: [state]
  @spec get_and_update( multiagent, fun_arg([state], {any, [state] | :pop}), [key], timeout)
        :: any
  def get_and_update( multiagent, fun, keys, timeout) when is_list( keys) do
    GenServer.call( multiagent, {:get_and_update, fun, keys}, timeout)
  end

  @spec get_and_update( multiagent, key, fun_arg( state, {a, state} | :pop), timeout)
        :: a | state when a: var
  def get_and_update( multiagent, key, fun, timeout) do
    GenServer.call( multiagent, {:get_and_update, key, fun}, timeout)
  end

  @doc """
  Version of `get_and_update/4` for use in batch processing. Be aware, that
  states for all keys are locked until callback is executed (see
  `get_and_update/4` for details).

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link()
      iex> MultiAgent.get( pid, alice: & &1, bob: & &1)
      [nil, nil]
      iex> MultiAgent.update( pid, alice: fn nil -> 42 end,
      ...>                         bob:   fn nil -> 24 end)
      :ok
      iex> MultiAgent.get( pid, alice: & &1, bob: & &1)
      [42, 24]
      iex> MultiAgent.update( pid, alice: & &1-10, bob: & &1+10)
      iex> MultiAgent.get( pid, alice: & &1, bob: & &1)
      [32, 34]
  """
  @spec get_and_update( multiagent, [{key, fun_arg( state, {any, state} | :pop)} | {:timeout, timeout}]) :: [any | state]
  def get_and_update( multiagent, funs_and_timeout) do
    batch_call( multiagent, funs_and_timeout, :get_and_update)
  end


  @doc """
  Updates multiagent state with given key. The callback `fun` will be sent to
  the `multiagent`, which will add it to the execution queue for the given key.
  Before the invocation, the multiagent state will be passed as the first
  argument. If `multiagent` has no state with such key, `nil` will be passed to
  `fun`. The return value of callback becomes the new state of the multiagent.

  Be aware that: (1) this function always returns `:ok`; (2) as a callback can be
  passed anonymous function, `{fun, args}` or MFA tuple; (3) every state has
  it's own FIFO queue of callbacks and all the queues are processed
  asynchronously.

  Also, list of keys could be passed to make transaction-like call. But: (1) in
  this case keys and fun arguments are swaped (list must be given as a third
  argument); (2) function given as argument should return the same size list of
  updated states; (3) all the corresponding states are locked until callback is
  executed for all keys (see `get_and_update/2`).

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the multiagent executes the function and
  returns the result value, or the atom `:infinity` to wait indefinitely. If no
  result is received within the specified time, the function call fails and the
  caller exits. If this happened but callback is so far in the queue, and in
  `init/4` call `:callexpired` option was set to true (by def.), it will still
  be executed.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link( key: fn -> 42 end)
      iex> MultiAgent.update( pid, :key, & &1+1)
      :ok
      iex> MultiAgent.get( pid, :key, & &1)
      43
      #
      iex> MultiAgent.update( pid, :otherkey, fn nil -> 42 end)
      :ok
      iex> MultiAgent.get( pid, :othekey, & &1)
      42
  """
  def update( multiagent, _, _, timeout \\ 5000)

  @spec update( multiagent, fun_arg( [state], [state]), [key], timeout) :: :ok
  def update( multiagent, fun, keys, timeout) when is_list( keys) do
    GenServer.call( multiagent, {:update, fun, keys}, timeout)
  end

  @spec update( multiagent, key, fun_arg( state, state), timeout) :: :ok
  def update( multiagent, key, fun, timeout) do
    GenServer.call( multiagent, {:update, key, fun}, timeout)
  end

  @doc """
  Version of `update/4` for use in batch processing. Be aware, that states for
  all keys are locked until callback is executed. See `get_and_update/4` for
  details and `get/2` for examples.
  """
  @spec update( multiagent, [{key, fun_arg( state, state)} | {:timeout, timeout}]) :: :ok
  def update( multiagent, funs_and_timeout) do
    batch_call( multiagent, funs_and_timeout, :update)
  end


  @doc """
  Performs a cast (*fire and forget*) operation on the multiagent state.

  The callbacks are sent to the `multiagent` which invokes them passing the
  multiagent state with given key. The return value becomes the new state of the
  multiagent.

  Note that `cast` returns `:ok` immediately, regardless of whether `multiagent`
  (or the node it should live on) exists.

  All over details are the same as with `update/4` and `update/2`.
  """
  @spec cast( multiagent, fun_arg( [state], [state]), [key]) :: :ok
  def cast( multiagent, fun, keys) when is_list( keys) do
    GenServer.cast( multiagent, {:update, fun, keys})
  end

  @spec cast( multiagent, key, fun_arg( state, state)) :: :ok
  def cast( multiagent, key, fun) do
    GenServer.cast( multiagent, {:update, key, fun})
  end

  @doc """
  Version of `cast/3` for use in batch processing. Be aware, that states for all
  involved keys are locked while callback is executed. See `update/2` for
  details.
  """
  @spec cast( multiagent, [{key, fun_arg( state, state)}]) :: :ok
  def cast( multiagent, funs) do
    keys = Keyword.keys( funs)
    funs = Keyword.values( funs)

    prun = fn {fun, state} ->
      Task.start_link( Callback.run( fun, [state]))
    end

    GenServer.cast( multiagent,
                    {:update, & Enum.zip( funs, &1) |> Enum.map( prun), keys})
  end


  @doc """
  Synchronously stops the multiagent with the given `reason`.

  It returns `:ok` if the multiagent terminates with the given reason. If the
  multiagent terminates with another reason, the call will exit.

  This function keeps OTP semantics regarding error reporting. If the reason is
  any other than `:normal`, `:shutdown` or `{:shutdown, _}`, an error report
  will be logged.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link( fn -> 42 end)
      iex> MultiAgent.stop( pid)
      :ok
  """
  @spec stop( multiagent, reason :: term, timeout) :: :ok
  def stop( multiagent, reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop( multiagent, reason, timeout)
  end

end

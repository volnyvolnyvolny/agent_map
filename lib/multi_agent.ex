defmodule MultiAgent do

  alias MultiAgent.{Callback, Server}


  @moduledoc """
  MultiAgent is an abstraction around **group** of states. Often in Elixir there
  is a need to share or store group of states that must be accessed from
  different processes or by the same process at different points in time. There
  are two main solutions: (1) use a group of `Agent`s; or (2) a
  `GenServer`/`Agent` that hold states in some key-value storage and provides
  concurrent access for different states. The `MultiAgent` module follows the
  latter approach. It stores states in a `Map` and when a changing callback
  comes in (via `update` or `get_and_update` functions), special temporary
  process (worker) that stores queue is created — `MultiAgent` respects order in
  which callbacks arrived. Moreover, `MultiAgent` supports changing a group of
  states simultaniously via built-in mechanism.

  Module provides a basic server implementation that allows states to be
  retrieved and updated via an API similar to the one of `Agent` and `Map`
  modules. Special struct can be made via `new/1` function to use `Enum` module
  and `[]` operator.

  ## Examples

  For example, let us manage tasks and projects. Each task can be in `:added`,
  `:started` or `:done` states. This is easy to do with a `MultiAgent`:

      defmodule TasksServer do
        use MultiAgent

        def start_link do
          MultiAgent.start_link( name: __MODULE__)
        end

        @doc "Add new project task" def add( project, task) do
        MultiAgent.init(__MODULE__, {project, task}, fn -> :added end) end

        @doc "Returns state of given task"
        def state( project, task) do
          MultiAgent.get(__MODULE__, {project, task}, & &1)
        end

        @doc "Returns list of all project tasks"
        def list( project) do
          tasks = MultiAgent.keys(__MODULE__)
          for {^project, task} <- tasks, do: task
        end

        @doc "Returns list of project tasks in given state"
        def list( project, state: state) do
          tasks = MultiAgent.keys(__MODULE__)
          for {^project, task} <- tasks,
              state( project, task) == state, do: task
        end

        @doc "Updates project task"
        def update( project, task, new_state) do
          MultiAgent.update(__MODULE__, {project, task}, fn _ -> new_state end)
        end

        @doc "Deletes given project task, returning state"
        def take( project, task) do
          MultiAgent.get_and_update(__MODULE__, {project, task}, fn _ -> :pop end)
        end
      end

  As in `Agent` module case, `MultiAgent` provide a segregation between the
  client and server APIs (similar to `GenServer`s). In particular, any changing
  state anonymous functions given to the `MultiAgent` is executed inside the
  multiagent (the server) and effectively block execution of any other function
  **on the same state** until the request is fulfilled. So it's important to
  avoid use of expensive operations inside the multiagent. See corresponding
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

  `MultiAgent` defines special struct that contains pid of the multiagent
  process. `Enumerable` protocol is implemented for this struct, that allows
  multiagent to be used with `Enum` module.

      iex> MultiAgent.new( key: 42) |>
      ...> Enum.empty?()
      false

  Similarly, `MultiAgent` follows `Access` behaviour, so `[]` operator could be
  used:

      iex> MultiAgent.new( a: 42, b: 24)[:a]
      42
  """

  @typedoc "Return values of `start*` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid} | term}

  @typedoc "The multiagent name"
  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "The multiagent reference"
  @type multiagent :: pid | {atom, node} | name | %MultiAgent{}

  @typedoc "The multiagent state key"
  @type key :: term

  @typedoc "The multiagent state"
  @type state :: term

  @typedoc "The multiagent \"extra\" GenServer state"
  @type extra :: term

  @typedoc "Anonymous function, `{fun, args}` or MFA triplet"
  @type fun_arg( a, r) :: (a -> r) | {(... -> r), [a | any]} | {module, atom, [a | any]}

  @typedoc "Anonymous function with zero arity, pair `{fun/length( args), args}` or corresponding MFA tuple"
  @type fun_arg( r) :: (() -> r) | {(... -> r), [any]} | {module, atom, [any]}


  @enforce_keys [:link]
  defstruct @enforce_keys

  @behaviour Access


  @doc false
  def child_spec( funs_and_opts) do
    %{
      id: MultiAgent,
      start: {MultiAgent, :start_link, [funs_and_opts]}
    }
  end


  @doc false
  defmacro __using__( opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @doc false
      def child_spec( funs_and_opts) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [funs_and_opts]}
        }

        Supervisor.child_spec( default, unquote( Macro.escape( opts)))
      end

      defoverridable child_spec: 1
    end
  end


  ## HELPERS ##

  defp pid(%__MODULE__{link: mag}), do: mag
  defp pid( mag), do: mag


  defguardp is_timeout(t) when t == :infinity or is_integer( t) and t >= 0


  defp call( action, multiagent, data, timeout, urgent \\ nil)

  defp call(:get, mag, data, timeout, :!) do
    GenServer.call pid( mag), {:!, {:get, data}}, timeout
  end

  defp call(:cast, mag, data, _, urgent) do
    if urgent do
      GenServer.cast pid( mag), {:!, {:cast, data}}
    else
      GenServer.cast pid( mag), {:cast, data}
    end
  end

  defp call( action, mag, data, timeout, urgent) do
    expires = System.system_time +
              System.convert_time_unit( timeout, :millisecond, :native)

    if urgent do
      GenServer.call pid( mag), {:!, {action, data, expires}}, timeout
    else
      GenServer.call pid( mag), {action, data, expires}, timeout
    end
  end


  defp batch( action, mag, funs, timeout, urgent) do
    results =
      Keyword.values( funs)
      |> Enum.map( &Task.async( fn ->
           call( action, mag, &1, timeout, urgent)
         end))
      |> Task.yield_many( timeout)
      |> Enum.map( fn {task, res} ->
           case res || Task.shutdown( task, :brutal_kill) do
             {:ok, result} -> result
             exit ->
               Process.exit( self(), exit || :timeout)
           end
         end)

    if action in [:update, :cast], do: :ok, else: results
  end


  ## ##


  # common for start_link and start
  defp separate( funs_and_opts) do
    {opts, funs} =
      Enum.reverse( funs_and_opts) |>
      Enum.split_while( fn {_,v} ->
        not Callback.valid?( v)
      end)

    {Enum.reverse( funs), opts}
  end


  defp check_opts( opts, keys) do
    keys = Keyword.keys(opts)--keys
    unless Enum.empty?(keys) do
      raise "Unexpected opts: #{keys}."
    end
  end


  @doc """
  Returns a new empty multiagent.

  ## Examples

      iex> mag = MultiAgent.new
      iex> Enum.empty? mag
      true
  """
  @spec new :: multiagent
  def new, do: new %{}


  @doc """
  Starts a `MultiAgent` via `start_link/1` function. `new/1` returns
  `MultiAgent` **struct** that contains pid of the `MultiAgent`.

  As the only argument, states keyword can be provided or already started
  multiagent.

  ## Examples

      iex> mag = MultiAgent.new( a: 42, b: 24)
      iex> mag[:a]
      42
      iex> MultiAgent.keys mag
      [:a, :b]

      iex> {:ok, pid} = MultiAgent.start_link()
      iex> mag = MultiAgent.new pid
      iex> MultiAgent.init( mag, a: fn -> 1 end)
      {:ok, 1}
      iex> mag[:a]
      1
  """
  @spec new( Enumerable.t() | multiagent) :: multiagent
  def new( enumerable)

  def new(%__MODULE__{}=mag), do: mag
  def new(%_{} = struct), do: new( Map.new( struct))
  def new( list) when is_list( list), do: new( Map.new list)
  def new(%{} = states) when is_map( states) do
    states = for {key, state} <- states do
      {key, fn -> state end}
    end

    {:ok, mag} = start_link states
    new mag
  end
  def new( mag), do: %__MODULE__{link: GenServer.whereis( mag)}


  @doc """
  Creates a multiagent from an `enumerable` via the given transformation
  function. Duplicated keys are removed; the latest one prevails.

  ## Examples

      iex> mag = MultiAgent.new([:a, :b], fn x -> {x, x} end)
      iex> MultiAgent.take mag, [:a, :b]
      %{a: :a, b: :b}
  """
  @spec new( Enumerable.t(), (term -> {key, state})) :: multiagent
  def new( enumerable, transform) do
    new Map.new( enumerable, transform)
  end


  @doc """
  Starts a multiagent linked to the current process with the given function.
  This is often used to start the multiagent as part of a supervision tree.

  The first argument is a list of pairs `{term, fun_arg}` (keyword, in
  particular). The second element of each pair is an anonymous function, `{fun,
  args}` or MFA-tuple with zero num of arguments.

  For each key, callback is executed as a separate `Task`.

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
  @spec start_link( [{term, fun_arg( any)} | GenServer.option]) :: on_start
  def start_link( funs_and_opts \\ [timeout: 5000]) do
    {funs, opts} = separate funs_and_opts
    timeout = opts[:timeout] || 5000
    opts = Keyword.put opts, :timeout, :infinity # turn off global timeout
    GenServer.start_link Server, {funs, timeout, nil}, opts
  end


  @doc """
  Starts a multiagent process without links (outside of a supervision tree).

  See `start_link/2` for details.

  ## Examples

      iex> MultiAgent.start( one: 42,
      ...>                   two: fn -> :timer.sleep(150) end,
      ...>                   three: fn -> :timer.sleep(:infinity) end,
      ...>                   timeout: 100)
      {:error, [one: :cannot_call, two: :timeout, three: :timeout]}

      iex> MultiAgent.start( one: :foo,
      ...>                   two: :bar,
      ...>                   three: fn -> :timer.sleep(:infinity) end,
      ...>                   timeout: 100)
      {:error, [key1: :already_exists]}

      iex> err = MultiAgent.start( one: 76, two: fn -> raise "oops" end)
      iex> {:error, [one: :cannot_call, two: {exception, _stacktrace}]} = err
      iex> exception
      %RuntimeError{ message: "oops"}
  """
  @spec start( [{term, fun_arg( any)} | GenServer.option]) :: on_start
  def start( funs_and_opts \\ [timeout: 5000]) do
    {funs, opts} = separate funs_and_opts
    timeout = opts[:timeout] || 5000
    opts = Keyword.put opts, :timeout, :infinity # turn off global timeout
    GenServer.start Server, {funs, timeout, nil}, opts
  end


  @doc """
  Initialize a multiagent state via the given anonymous function with zero
  arity, `{fun/length(args), args}` or corresponding MFA triplet. The callback
  is sent to the `multiagent` which invokes it in `GenServer` call.

  Its return value is used as the multiagent state with given key. Note that
  `init/4` does not return until the given callback has returned.

  State may also be added via `update/4` or `get_and_update/4` functions:

      update( multiagent, :alice, fn nil -> :'200$' end)
      update( multiagent, fn _ -> [:'100000000$', :'0$'] end, [:rich, :poor])
      # remember to never store arbitrary atoms as they are not GC ;)

  ## Options

  `:timeout` option specifies an integer greater than zero which defines how
  long (in milliseconds) multiagent is allowed to spend on initialization before
  init task will be `Task.shutdown(…, :brutal_kill)`ed and this function will
  return `{:error, :timeout}`. Also, the atom `:infinity` can be provided to
  make multiagent wait infinitely.

  `:late_call` option specifies should multiagent execute functions that are
  expired. This happend when caller timeout is took place before function
  execution.

  Multiagent can execute `get` calls on the same key in parallel. `max_threads`
  option specifies number of threads per key used. By default two `get` calls on
  the same state could be executed, so

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
  Parallelization uses no more than `max_threads`.

  Use `max_threads: 1` to execute `get` calls in sequence.

  ## Examples

      iex> mag = MultiAgent.new()
      iex> MultiAgent.get( mag, :k, & &1)
      nil
      iex> MultiAgent.init( mag, :k, fn -> 42 end)
      {:ok, 42}
      iex> MultiAgent.get( mag, :k, & &1)
      42
      iex> MultiAgent.init( mag, :k, fn -> 43 end)
      {:error, {:k, :already_exists}}
      #
      iex> MultiAgent.init( mag, :_, fn -> :timer.sleep(300) end, timeout: 200)
      {:error, :timeout}
      iex> MultiAgent.init( mag, :k, fn -> :timer.sleep(300) end, timeout: 200)
      {:error, {:k, :already_exists}}
      iex> MultiAgent.init( mag, :k2, fn -> 42 end, late_call: false)
      {:ok, 42}
      iex> MultiAgent.cast( mag, :k2, & :timer.sleep(100) && &1) #blocks for 100 ms
      iex> MultiAgent.update( mag, :k, fn _ -> 0 end, timeout: 50)
      {:error, :timeout}
      iex> MultiAgent.get( mag, :k, & &1) #update was not happend
      42
  """
  @spec init( multiagent, key, fun_arg( a), [ {:timeout, timeout}
                                            | {:late_call, boolean}
                                            | {:max_threads, pos_integer | :infinity}])
        :: {:ok, a}
         | {:error, {key, :already_exists}} when a: var
  def init( multiagent, key, fun, opts \\ [timeout: 5000]) do
    check_opts opts, [:late_call, :timeout, :max_threads]
    {timeout, opts} = Keyword.pop opts, :timeout, 5000

    call :init, multiagent, {key, fun, opts}, timeout
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

      iex> mag = MultiAgent.new()
      iex> MultiAgent.get( mag, :alice, & &1)
      nil
      iex> MultiAgent.init( mag, :alice, fn -> 42 end)
      42
      iex> MultiAgent.get( mag, :alice, & &1)
      42
      iex> MultiAgent.get( mag, :alice, & &1+1)
      43
      #
      # aggregate calls:
      #
      iex> MultiAgent.init( mag, :bob, fn -> 43 end)
      43
      iex> MultiAgent.get( mag, &Enum.sum/1, [:alice, :bob])
      85
      # order matters:
      iex> MultiAgent.get( mag, {&Enum.reduce/3, [0, &-/2]}, [:alice, :bob])
      1
      iex> MultiAgent.get( mag, {&Enum.reduce/3, [0, &-/2]}, [:bob, :alice])
      -1

  ## Urgent (`:!`)

  Urgent version of `get` can be used to make out of turn async call. State can
  have an associated queue of callbacks, waiting to be executed. This version
  works as `get`, but retrives state immediately at the moment of call. No
  matter of current number of threads used for involved state(s) it is called
  in a separate `Task`.

  ## Examples

      iex> mag = MultiAgent.new( key: 42)
      iex> MultiAgent.cast( mag, :key, fn _ ->
      ...>   :timer.sleep( 100)
      ...>   43
      ...> end)
      iex> MultiAgent.get( mag, :!, :key, & &1)
      42
      iex> MultiAgent.get( mag, :key, & &1)
      43
      iex> MultiAgent.get( mag, :!, :key, & &1)
      43
  """
  @spec get( multiagent, :!, fun_arg([state], a), [key], timeout) :: a when a: var
  @spec get( multiagent, :!, key, fun_arg( state, a), timeout) :: a when a: var

  # 5
  def get( multiagent, :!, fun, keys, timeout) when is_list( keys) do
    GenServer.call multiagent, {:!, {:get, {fun, keys}}}, timeout
  end
  def get( multiagent, :!, key, fun, timeout) do
    call :get, multiagent, {key, fun}, timeout, :!
  end


  @doc """
  See `get/5`.
  """
  @spec get( multiagent, :!, timeout, [{key, fun_arg( state, any)}]) :: [any]
  @spec get( multiagent, :!, fun_arg([state], a), [key]) :: a when a: var
  @spec get( multiagent, :!, key, fun_arg( state, a)) :: a when a: var

  @spec get( multiagent, fun_arg([state], a), [key], timeout) :: a when a: var
  @spec get( multiagent, key, fun_arg( state, a), timeout) :: a when a: var

  # 4
  def get( multiagent, :!, timeout, funs) when is_timeout( timeout) and is_list( funs) do
    batch :get, multiagent, funs, timeout, :!
  end
  def get( multiagent, :!, fun, keys) when is_list( keys) do
    get multiagent, :!, fun, keys, 5000
  end
  def get( multiagent, :!, key, fun) do
    get multiagent, :!, key, fun, 5000
  end

  def get( multiagent, fun, keys, timeout) when is_list( keys) and is_timeout( timeout) do
    call :get, multiagent, {fun, keys}, timeout, nil
  end
  def get( multiagent, key, fun, timeout) when is_timeout( timeout) do
    call :get, multiagent, {key, fun}, timeout, nil
  end

  @spec get( multiagent, fun_arg([state], a), [key]) :: a when a: var
  @spec get( multiagent, key, fun_arg( state, a)) :: a when a: var
  @spec get( multiagent, :!, [{key, fun_arg( state, any)}]) :: [any]
  @spec get( multiagent, timeout, [{key, fun_arg( state, any)}]) :: [any]
  @spec get( multiagent, key, fun_arg( state, a) | a) :: state | a when a: var

  # 3
  def get( multiagent, key, default)

  def get( multiagent, :!, funs) when is_list( funs) do
    get multiagent, :!, 5000, funs
  end
  def get( multiagent, timeout, funs) when is_timeout( timeout) and is_list( funs) do
    batch :get, multiagent, funs, timeout, nil
  end

  def get( multiagent, fun, keys) when is_list( keys) do
    call :get, multiagent, {fun, keys}, 5000, nil
  end

  def get( multiagent, key, fun_or_default) do
    if Callback.valid? fun_or_default, 1 do
      fun = fun_or_default # ambiguity fix
      call :get, multiagent, {key, fun}, 5000, nil
    else
      # Say hi to Access behaviour!
      default = fun_or_default # ambiguity fix
      GenServer.call multiagent, {:!, {:get, key, default}}
    end
  end


  @doc """
  Version of `get/5` to be used for batch processing. As in `get/5`, urgent
  (`:!`) mark can be provided to make out of turn call. Works the same as
  `get_and_update/4`, `update/4` and `cast/3`.

  ## Examples

      iex> mag = MultiAgent.new()
      iex> MultiAgent.get( mag, alice: & &1, bob: & &1)
      [nil, nil]
      iex> MultiAgent.update( mag, alice: fn nil -> 42 end,
      ...>                         bob:   fn nil -> 24 end)
      :ok
      iex> MultiAgent.get( mag, alice: & &1, bob: & &1)
      [42, 24]
      iex> MultiAgent.update( mag, alice: & &1-10, bob: & &1+10)
      iex> MultiAgent.get( mag, alice: & &1, bob: & &1)
      [32, 34]
  """
  @spec get( multiagent, [{key, fun_arg( state, any)}]) :: [any]
  def get( multiagent, funs) when is_list( funs) do
    if Enum.any? funs, & !Callback.valid?(&1, 1) do
      key = funs # ambiguity fix
      get multiagent, key, nil
    else
      batch :get, multiagent, funs, 5000, nil
    end
  end

  @spec get( multiagent, key) :: state | nil
  def get( multiagent, key), do: get multiagent, key, nil


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

  Be aware that: (1) anonymous function, `{fun, args}` or MFA tuple can be
  passed as a callback; (2) every state has it's own FIFO queue of callbacks
  waiting to be executed and all the queues are processed asynchronously; (3) no
  state changing callbacks (`get_and_update`, `update` or `cast` calls) can be
  executed in parallel on the same state. This would be done only for `get`
  calls (see `max_threads` option of `init/4`).

  ## Transaction calls

  Transaction (group) call could be made by passing list of keys and callback
  that takes list of states with given keys and returns list of get values and
  new states:

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

  Callback must return list of `{get, new_state} | :id | :pop`, where `:pop` and
  `:id` make keys states to be returned as it is, and `:pop` will make the state
  be removed:

      iex> mag = MultiAgent.new( alice: 42, bob: 24)
      iex> MultiAgent.get_and_update( mag, fn _ -> [:pop, :id] end, [:alice, :bob])
      [42, 24]
      iex> MultiAgent.get( mag, & &1, [:alice, :bob])
      [nil, 24]

  Also, as in the error statement of previous example, callback may return pair
  `{get, [new_state]}`. This way aggregated value will be returned and all the
  corresponding states will be updated.

  And finally, callback may return `:pop` to return and remove all given states.

  (!) State changing transaction (such as `get_and_update`) will block all the
  involved states queues until the end of execution. So, for example,

      iex> MultiAgent.new( alice: 42, bob: 24, chris: 0) |>
      ...> MultiAgent.get_and_update(&:timer.sleep(1000) && {:slept_well, &1}, [:alice, :bob])
      :slept_well

  will block the possibility to `get_and_update`, `update`, `cast` and even
  `get` `:alice` and `:bob` states for 1 sec. Nonetheless states are always
  available for "urgent" `get` calls and `:chris` state is not blocked.

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
  `init/4` call `:late_call` flag is set to true, it will still be executed.

  ## Examples

      iex> import MultiAgent
      iex> mag = new( uno: 22, dos: 24, tres: 42, cuatro: 44)
      iex> get_and_update( mag, :uno, & {&1, &1 + 1})
      22
      iex> get( mag, :uno, & &1)
      23
      #
      iex> get_and_update( mag, :tres, fn _ -> :pop end)
      42
      iex> get( mag, :tres, & &1)
      nil
      #
      # transaction calls:
      #
      iex> get_and_update( mag, fn [u, d] ->
      ...>   [{u, d}, {d, u}]}
      ...> end, [:uno, :dos])
      [23, 24]
      iex> get( mag, & &1, [:uno, :dos])
      [24, 23]
      #
      iex> keys = [:uno, :dos, :tres, :cuatro]
      iex> get_and_update( mag, fn _ -> :pop, [:dos])
      [42]
      iex> get( pid, & &1, keys)
      [24, nil, nil, 44]
      #
      iex> get_and_update( mag, fn _ ->
      ...>   [:id, {nil, :_}, {:_, nil}, :pop]
      ...> end, keys)
      [24, nil, :_, 44]
      iex> get( mag, & &1, keys)
      [24, :_, nil, nil]
  """
  @spec get_and_update( multiagent, :!, fun_arg([state], [{any, state} | :pop | :id]), [key], timeout)
        :: [any | state]
  @spec get_and_update( multiagent, :!, fun_arg([state], :pop), [key], timeout, :! | nil)
        :: [state]
  @spec get_and_update( multiagent, fun_arg([state], {any, [state] | :pop}), [key], timeout, :! | nil)
        :: any
  @spec get_and_update( multiagent, key, fun_arg( state, {a, state} | :pop), timeout, :!)
        :: a | state when a: var

  def get_and_update( multiagent, :!, fun, keys, timeout) when is_list( keys) and is_timeout( timeout) do
    call :get_and_update, multiagent, {fun, keys}, timeout, urgent
  end

  def get_and_update( multiagent, key, fun, timeout, urgent) do
    call :get_and_update, multiagent, {key, fun}, timeout, urgent
  end


  @doc """
  Version of `get_and_update/5` to be used for batch processing. As in
  `get_and_update/5`, urgent (`:!`) mark can be provided to make out of turn
  call. Works the same as `get/4`, `update/4`.
  """
  @spec get_and_update( multiagent, timeout, :! | nil, [{key, fun_arg( state, :pop | {any, state})}])
        :: [state | any]
  def get_and_update( multiagent, timeout, urgent, funs) do
    {timeout, urgent} = fix timeout, urgent
    batch :get, multiagent, timeout, urgent, funs
  end


  # @doc """
  # Updates multiagent state with given key. The callback `fun` will be sent to
  # the `multiagent`, which will add it to the execution queue for the given key
  # state. Before the invocation, the multiagent state will be passed as the first
  # argument. If `multiagent` has no state with such key, `nil` will be passed to
  # `fun`. The return value of callback becomes the new state of the multiagent.

  # Be aware that: (1) this function always returns `:ok`; (2) anonymous function,
  # `{fun, args}` or MFA tuple can be passed as a callback; (3) every state has
  # it's own FIFO queue of callbacks waiting for execution and queues for
  # different states are processed in parallel.

  # ## Transaction calls

  # Transaction (group) call could be made by passing list of keys and callback
  # that takes list of states with given keys and returns list of new states. See
  # corresponding `get/5` docs section.

  # Callback must return list of new states or `:drop` to remove all given states:

  #     iex> mag = MultiAgent.new( alice: 42, bob: 24, chris: 33, dunya: 51)
  #     iex> MultiAgent.update( mag, &Enum.reverse/1, [:alice, :bob])
  #     :ok
  #     iex> MultiAgent.update( mag, fn _ -> :pop end, [:alice, :bob])
  #     :ok
  #     iex> MultiAgent.keys( mag)
  #     [:chris]
  #     iex> MultiAgent.update( mag, fn _ -> :pop end, [:chris])
  #     # but:
  #     iex> MultiAgent.update( mag, :dunya, fn _ -> :pop end)
  #     iex> MultiAgent.get( mag, & &1, [:chris, :dunya])
  #     [nil, :pop]

  # (!) State changing transaction (such as `update`) will block all the involved
  # states queues until the end of execution. So, for example,

  #     iex> MultiAgent.new( alice: 42, bob: 24, chris: 0) |>
  #     ...> MultiAgent.update(&:timer.sleep(1000) && :drop, [:alice, :bob])
  #     :ok

  # will block the possibility to `get_and_update`, `update`, `cast` and even
  # `get` `:alice` and `:bob` states for 1 sec. Nonetheless states are always
  # available for "urgent" `get` calls and `:chris` state is not blocked.

  # ## Timeout

  # `timeout` is an integer greater than zero which specifies how many
  # milliseconds are allowed before the multiagent executes the function and
  # returns the result value, or the atom `:infinity` to wait indefinitely. If no
  # result is received within the specified time, the function call fails and the
  # caller exits. If this happened but callback is so far in the queue, and in
  # `init/4` call `:late_call` option was set to true (by def.), it will still be
  # executed.

  # ## Examples

  #     iex> {:ok, pid} = MultiAgent.start_link( key: fn -> 42 end)
  #     iex> MultiAgent.update( pid, :key, & &1+1)
  #     :ok
  #     iex> MultiAgent.get( pid, :key, & &1)
  #     43
  #     #
  #     iex> MultiAgent.update( pid, :otherkey, fn nil -> 42 end)
  #     :ok
  #     iex> MultiAgent.get( pid, :othekey, & &1)
  #     42
  # """
  # def update( multiagent, _, _, timeout \\ 5000, urgent \\ nil)

  # @spec update( multiagent, fun_arg( [state], [state] | :drop), [key], timeout, :! | nil) :: :ok
  # def update( multiagent, fun, keys, timeout, urgent) when is_list( keys) do
  #   {timeout, urgent} = fix timeout, urgent
  #   call :update, multiagent, {fun, keys}, timeout, urgent
  # end

  # @spec update( multiagent, key, fun_arg( state, state), timeout, :! | nil) :: :ok
  # def update( multiagent, key, fun, timeout, urgent) do
  #   {timeout, urgent} = fix timeout, urgent
  #   call :update, multiagent, {key, fun}, timeout, urgent
  # end


  # @doc """
  # Version of `update/5` to be used for batch processing. As in `update/5`,
  # urgent (`:!`) mark can be provided to make out of turn call. Works the same as
  # `get/4` and `get_and_update/4`.
  # """
  # @spec update( multiagent, timeout, :! | nil, [{key, fun_arg( state, state)}]) :: :ok
  # def update( multiagent, timeout, urgent, funs) do
  #   {timeout, urgent} = fix timeout, urgent
  #   batch :get, multiagent, timeout, urgent, funs
  # end


  # @doc """
  # Performs a cast (*fire and forget*) operation on the multiagent state. It's
  # all the same as `update/5` but returns `:ok` immediately, regardless of
  # whether `multiagent` (or the node it should live on) exists.

  # See `update/5` for details.
  # """
  # def cast( multiagent, fun, keys, urgent \\ nil)

  # @spec cast( multiagent, fun_arg( [state], [state]), [key], :! | nil) :: :ok
  # def cast( multiagent, fun, keys, urgent) when is_list( keys) do
  #   {:noreply, Transaction.run( {:cast, {fun, keys}}, urgent)}
  # end

  # @spec cast( multiagent, key, fun_arg( state, state), :! | nil) :: :ok
  # def cast( multiagent, key, fun, urgent) do
  #   call(:cast, multiagent, {key, fun}, urgent)
  # end


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
    GenServer.stop pid( multiagent), reason, timeout
  end


  @doc """
  Fetches the value for a specific `key` in the given `multiagent`.

  If `multiagent` contains the given `key` with value value, then `{:ok, value}`
  is returned. If `map` doesn’t contain `key`, `:error` is returned.

  Examples

      iex> mag = MultiAgent.new(a: 1)
      iex> MultiAgent.fetch( mag, :a)
      {:ok, 1}
      iex> MultiAgent.fetch( mag, :b)
      :error
  """
  @spec fetch( multiagent, key) :: {:ok, state} | :error
  def fetch( multiagent, key) do
    GenServer.call pid( multiagent), {:!, {:fetch, key}}
  end

  @doc """
  Returns whether the given `key` exists in the given `multimap`.

  ## Examples

      iex> mag = MultiAgent.new( a: 1)
      iex> MultiAgent.has_key?( mag, :a)
      true
      iex> MultiAgent.has_key?( mag, :b)
      false
  """
  @spec has_key?( multiagent, key) :: boolean
  def has_key?( multiagent, key) do
    GenServer.call pid( multiagent), {:has_key?, key}
  end


  @doc """
  Fetches the value for a specific `key` in the given `multiagent`, erroring out
  if `multiagent` doesn't contain `key`. If `multiagent` contains the given
  `key`, the corresponding value is returned. If `multiagent` doesn't contain
  `key`, a `KeyError` exception is raised.

  ## Examples

      iex> mag = MultiAgent.new( a: 1)
      iex> MultiAgent.fetch!( mag, :a)
      1
      iex> MultiAgent.fetch!( mag, :b)
      ** (KeyError) key not found in multiagent
  """
  @spec fetch!( multiagent, key) :: state | no_return
  def fetch!( multiagent, key) do
    case GenServer.call pid( multiagent), {:!, {:fetch, key}} do
      {:ok, state} -> state
      :error -> raise KeyError, message: "key not found in multiagent"
    end
  end


  @doc """
  Returns a `Map` with all the key-value pairs in `multiagent` where the key is
  in `keys`. If `keys` contains keys that are not in `multimap`, they're simply
  ignored.

  ## Examples
      iex> mag = MultiAgent.new( a: 1, b: 2, c: 3)
      iex> MultiAgent.take( mag, [:a, :c, :e])
      %{a: 1, c: 3}
  """
  @spec take( multiagent, Enumerable.t()) :: map
  def take( multiagent, keys) do
    GenServer.call pid( multiagent), {:!, {:take, keys}}
  end


  # @doc """
  # Deletes the entry in `multiagent` for a specific `key`. If the `key` does not
  # exist, returns `multiagent` unchanged.

  # Syntax sugar to `get_and_update( multiagent, key, fn _ -> :pop end, :!)`.

  # ## Examples

  #     iex> mag = MultiAgent.new( a: 1, b: 2)
  #     iex> MultiAgent.delete mag, :a
  #     iex> MultiAgent.take mag, [:a, :b]
  #     %{b: 2}
  #     iex> MultiAgent.delete mag, :a
  #     iex> MultiAgent.take mag, [:a, :b]
  #     %{b: 2}
  # """
  # @spec delete( multiagent, key) :: multiagent
  # def delete( multiagent, key) do
  #   get_and_update multiagent, key, fn _ -> :pop end, :!
  #   multiagent
  # end


  # @doc """
  # Drops the given `keys` from `multiagent`. If `keys` contains keys that are not
  # in `multiagent`, they're simply ignored.

  # Syntax sugar to transaction call

  #     get_and_update( multiagent, fn _ -> :pop end, keys, :!)

  # ## Examples

  #     iex> mag = MultiAgent.new( a: 1, b: 2, c: 3)
  #     iex> MultiAgent.drop mag, [:b, :d]
  #     iex> MultiAgent.keys mag
  #     [:a, :c]
  # """
  # @spec drop( multiagent, Enumerable.t()) :: multiagent
  # def drop( multiagent, keys) do
  #   get_and_update( multiagent, fn _ -> :pop end, keys, :!)
  #   multiagent
  # end

end

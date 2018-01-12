defmodule MultiAgent do

  @moduledoc """
  MultiAgent is a simple abstraction around **group** of states. Often in Elixir
  there is a need to share or store group of states that must be accessed from
  different processes or by the same process at different points in time. There
  are two main solutions: (1) use a group of `Agent`s; or (2) a
  `GenServer`/`Agent` that hold states in some key-value storage
  (ETS/`Map`/process dictionary) and provides concurrent access for different
  states. The `MultiAgent` module follows the latter approach. It stores states
  in `Map` and provides a basic server implementation that allows states to be
  retrieved and updated via an API similar to the one of `Agent` and `Map`
  modules.

  ## Examples

  For example, let us manage tasks and projects. Each task can have `:added`,
  `:started` or `:done` state. This is easy to implement with a `MultiAgent`:

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
          MultiAgent.lookup(__MODULE__, fn _ -> true end)
        end

        @doc "Returns list of tasks for project in given state"
        def list( project, state: state) do
          MultiAgent.lookup(__MODULE__, & &1 == state)
        end

        @doc "Updates task for project"
        def update( task, project, new_state) do
          MultiAgent.update(__MODULE__, {task, project}, fn _ -> new_state end)
        end

        @doc "Deletes given task for project, returning state"
        def take( task, project) do
          MultiAgent.get_and_update(__MODULE__, {task, project}, & {&1, nil})
        end
      end

  As in `Agent` module case, `MultiAgent` provide a segregation between the client
  and server APIs (similar to GenServers). In particular, any anonymous functions
  given to the `MultiAgent` is executed inside the multiagent (the server) and
  effectively block execution of any other function **on the same state** until
  the request is fulfilled. So it's important to avoid use of expensive operations
  inside the multiagent (see, `Agent`). See corresponding `Agent` docs section.

  Finally note `use MultiAgent` defines a `child_spec/1` function, allowing the
  defined module to be put under a supervision tree. The generated
  `child_spec/1` can be customized with the following options:

    * `:id` - the child specification id, defauts to the current module
    * `:start` - how to start the child process (defaults to calling `__MODULE__.start_link/1`)
    * `:restart` - when the child should be restarted, defaults to `:permanent`
    * `:shutdown` - how to shut down the child

  For example:

      use MultiAgent, restart: :transient, shutdown: 10_000

  See the `Supervisor` docs for more information.

  ## Name registration

  An multiagent is bound to the same name registration rules as GenServers.
  Read more about it in the `GenServer` documentation.

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

  # Using `Enum` module and `[:key]` operator

  Via `p_enum` package that implements `Enumerable` for processes (may be
  named). After it's added to your deps, `Enum` could be used to interact
  with this multiagent.

      > {:ok, multiagent} = MultiAgent.start()
      > Enum.empty? multiagent
      true
      > MultiAgent.init(:key, fn -> 42 end)
      42
      > Enum.empty? multiagent
      false

  Similarly, `p_access` package implements `Access` protocol, so adding it
  to your deps gives a nice syntax sugar:

      > {:ok, multiagent} = MultiAgent.start(:key, fn -> 42 end)
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

  @typedoc "fun | {fun, args} | {Module, fun, args}"
  @type fun_arg :: fun | {fun, [any]} | {module, atom, [any]}


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


  # is function given in form of {M,f,args}, {f,args}
  # or other. Needed args num after arguments apply could be
  # specified
  defp fun?( fun, args_num \\ 0)

  defp fun?( {module, fun, args}, args_num) when is_atom( module) do
    fun?( {fun, args}, args_num)
  end

  defp fun?( {fun, args}, args_num) when is_list( args) do
    fun?( fun, length( args)+args_num)
  end

  defp fun?( fun, args_num), do: is_function( fun, args_num)


  # common for start_link and start
  defp prepair( inits, []) do
    {opts, inits} = Enum.reverse( inits)
                    |> Enum.split_while( fn {_,v} -> not fun?( v) end)

    {inits, Enum.reverse( opts)}
  end


  @doc """
  Starts a multiagent linked to the current process with the given function.
  This is often used to start the multiagent as part of a supervision tree.

  As the first argument list of tuples in form of `{id, fun/0}` can be given.
  See examples.

  ## Options

  The `:name` option is used for registration as described in the module
  documentation.

  If the `:timeout` option is present, the agent is allowed to spend at most
  the given number of milliseconds on initialization or it will be terminated
  and the start function will return `{:error, :timeout}`.

  If the `:debug` option is present, the corresponding function in the
  [`:sys` module](http://www.erlang.org/doc/man/sys.html) will be invoked.

  If the `:spawn_opt` option is present, its value will be passed as options
  to the underlying process as in `Process.spawn/4`.

  ## Return values

  If the server is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a multiagent with the
  specified name already exists, the function returns
  `{:error, {:already_started, pid}}` with the PID of that process.

  If the given function callback fails, the function returns `{:error, reason}`.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link( key: fn -> 42 end)
      iex> MultiAgent.get( pid, :key, & &1)
      42
      iex> MultiAgent.get( pid, :errorkey, & &1)
      nil

      iex> MultiAgent.start_link( key1: fn -> :timer.sleep( 250) end,
                                  key2: fn -> :timer.sleep( 600) end,
                                  timeout: 500)
      {:error, :timeout}

      iex> {:ok, pid} = MultiAgent.start_link( name: :multiagent)
      iex> MultiAgent.start_link( name: :multiagent)
      {:error, {:already_started, pid}}

      iex> MultiAgent.start_link( key: fn -> 42 end,
                                  key: fn -> 43 end)
      {:error, {:init, {:already_has, :key}}}

      iex> MultiAgent.start_link( key: 76,
                                  key: fn -> 43 end)
      {:error, {:init, {:is_not_fun, :key}}}
  """
  @spec start_link( keyword( fun_arg), GenServer.options) :: on_start
  def start_link( inits \\ [], options \\ []) do
    {inits, opts} = prepair( inits, options)
    GenServer.start_link( MultiAgent.Server, inits, opts)
  end

  @doc """
  Starts an multiagent process without links (outside of
  a supervision tree).

  See `start_link/2` for more information.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start( key: fn -> 42 end)
      iex> MultiAgent.get( pid, :key, & &1)
      42
      iex> {:error, {:badarith, _}} = MultiAgent.start( key: fn -> 1/0 end)
  """
  @spec start( keyword( fun_arg), GenServer.options) :: on_start
  def start( inits \\ [], options \\ []) do
    {inits, opts} = prepair( inits, options)
    GenServer.start( MultiAgent.Server, inits, opts)
  end


  @doc """
  Initialize a multiagent state via the given anonymous function, `{fun, args}`
  or MFA tuple. The function `fun` is sent to the `multiagent` which invokes it
  as a `Task`.

  Its return value is used as the multiagent state with given id. Note that
  `init/4` does not return until the given function has returned.

  State may also be added via `update/4` or `get_and_update/4` functions:

      update( multiagent, :key, fn nil -> :state end)
      update( multiagent, fn _ -> [:s1, :s2] end, [:key1, :key2])

  `timeout` is an integer greater than zero which specifies how many number of
  milliseconds multiagent is allowed to spend on initialization or it will be
  terminated and this function will return `{:error, :timeout}`. Also, the atom
  `:infinity` can be provided to make multiagent wait indefinitely.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link()
      iex> MultiAgent.get( pid, :key, & &1)
      nil
      iex> MultiAgent.init( pid, :key, fn -> 42 end)
      42
      iex> MultiAgent.get( pid, :key, & &1)
      42

      iex> MultiAgent.init( pid, :key, fn -> 43 end)
      {:error, {:already, :key}}

      iex> MultiAgent.init( pid, :key, fn -> :timer.sleep( 300) end, 200)
      {:error, {:already, :key}}
      iex> MultiAgent.init( pid, :_, fn -> :timer.sleep( 300) end, 200)
      {:error, :timeout}
  """
  @spec init( multiagent, key, fun_arg, timeout)
          :: any | {:error, :timeout}
                 | {:error, {:already | :is_not_fun, key}}
  def init( multiagent, key, fun, timeout \\ 5000) do
    GenServer.call( multiagent, {:init, key, fun}, timeout)
  end



  @doc """
  Gets the multiagent state with given key. The function `fun` is sent to the
  `multiagent` which invokes the function passing the multiagent state. The
  result of the function invocation is returned from this function.

  If there is no state with such key, `nil` will be passed to fun.

  Also, keys list could be passed to make transaction-like call. Be aware,
  that in this case keys and fun arguments are swaped (keys list must be given
  as a third argument).

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the multiagent executes the function and
  returns the result value, or the atom `:infinity` to wait indefinitely. If
  no result is received within the specified time, the function call fails
  and the caller exits. See `flush/2` if queue clean for state is needed.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link()
      iex> MultiAgent.get( pid, :key, & &1)
      nil
      iex> MultiAgent.init( pid, :key, fn -> 42 end)
      42
      iex> MultiAgent.get( pid, :key, & &1)
      42
      iex> MultiAgent.get( pid, :key, & 1+&1)
      43

      iex> MultiAgent.init( pid, :key2, fn -> 43 end)
      43
      iex> MultiAgent.get( pid, &Enum.sum/1, [:key, :key2])
      85

      iex> MultiAgent.get( pid, {&Enum.reduce/3, [0, &-/2]}, [:key, :key2])
      1
      iex> MultiAgent.get( pid, {&Enum.reduce/3, [0, &-/2]}, [:key2, :key])
      -1
  """
  def get( multiagent, _, _, timeout \\ 5000)

  @spec get( multiagent, fun_arg, [key], timeout) :: any
  def get( multiagent, fun, keys, timeout) when is_list( keys) do
    GenServer.call( multiagent, {:get, fun, keys}, timeout)
  end

  @spec get( multiagent, key, fun_arg, timeout) :: any
  def get( multiagent, key, fun, timeout) do
    GenServer.call( multiagent, {:get, key, fun}, timeout)
  end


  @doc """
  Works as `get/4`, but executes function in a separate process. Every state
  has an associated queue of calls to be made on it. Using `get!/4` the state
  with given key can be retrived immediately, "out of queue turn".

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

  @spec get!( multiagent, fun_arg, [key], timeout) :: any
  def get!( multiagent, fun, keys, timeout) when is_list( keys) do
    GenServer.call( multiagent, {:get!, fun, keys}, timeout)
  end

  @spec get!( multiagent, key, fun_arg, timeout) :: any
  def get!( multiagent, key, fun, timeout) do
    GenServer.call( multiagent, {:get!, key, fun}, timeout)
  end


  @doc """
  Gets and updates the multiagent state in one operation via the given
  anonymous function, `{fun, args}` pair or MFA tuple.

  The function `fun` is sent to the `multiagent` which invokes the function
  passing the multiagent state with given key (or `nil` if there is no such
  key). The function must return a tuple with two elements, the first being the
  value to return (that is, the "get" value) and the second one being the new
  state with such key of the multiagent.

  `fun` may also return `:pop`, which means the current value shall be removed
  from `multiagent` and returned (making this function behave similar to
  `Map.get_and_update/3`).

  Also, list of keys may be passed to make transaction-like calls. Be aware,
  that in this case keys and fun arguments are swaped (list must be given as the
  third argument). `fun` must return list of `{get, new_state}` pairs. Also,
  `:pop` atom may be given as the list argument, which removes corresponding
  state. And also, if `fun` return `:pop` — all states with given keys will be
  removed.

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the multiagent executes the function and
  returns the result value, or the atom `:infinity` to wait indefinitely. If no
  result is received within the specified time, the function call fails and the
  caller exits. See `flush/2` if queue clean for state is needed.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link( key1: fn -> 22 end,
                                               key2: fn -> 24 end,
                                               key3: fn -> 42 end,
                                               key4: fn -> 44 end)
      iex> MultiAgent.get_and_update( pid, :key1, & {&1, &1 + 1})
      22
      iex> MultiAgent.get( pid, :key1, & &1)
      23

      iex> MultiAgent.get_and_update( pid, :key3, fn _ -> :pop end)
      42
      iex> MultiAgent.get( pid, :key3, & &1)
      nil

      # transaction-like calls:
      iex> MultiAgent.get_and_update( pid, fn [s1, s2] -> [{s1, s2},{s2, s1}]} end, [:key1, :key2])
      [23, 24]
      iex> MultiAgent.get( pid, & &1, [:key1, :key2])
      [24, 23]

      iex> MultiAgent.get_and_update( pid, fn _ -> :pop, [:key2])
      [42]
      iex> MultiAgent.get( pid, & &1, [:key1, :key2, :key3, :key4])
      [24, nil, nil, 44]

      iex> MultiAgent.get_and_update( pid, fn _ -> [{nil, :s}, {:s, nil}, :pop] end, [:key2, :key3, :key4])
      [nil, :s, 44]
      iex> MultiAgent.get( pid, & &1, [:key1, :key2, :key3, :key4])
      [24, :s, nil, nil]
  """
  def get_and_update( multiagent, fun, keys, timeout \\ 5000)

  @spec get_and_update( multiagent, fun_arg, [key], timeout) :: any
  def get_and_update( multiagent, fun, keys, timeout) when is_list( keys) do
    GenServer.call( multiagent, {:get_and_update, fun, keys}, timeout)
  end

  @spec get_and_update( multiagent, key, fun_arg, timeout) :: any
  def get_and_update( multiagent, key, fun, timeout) do
    GenServer.call( multiagent, {:get_and_update, key, fun}, timeout)
  end


  @doc """
  Updates the multiagent state via the given anonymous function, `{fun,
  args}` or MFA tuple.

  The function `fun` is sent to the `multiagent` which invokes the function
  passing the multiagent state with given key. The return value of `fun`
  becomes the new state of the multiagent.

  Every state has it's own FIFO queue that is processed in a separate process,
  so update of one state will not block processing of others states queues.

  This function always returns `:ok`.

  If there is no state with given key, `nil` will be passed to update fun.
  Unlike `get_and_update/4`, if result of fun execution is `nil`,
  state with given key will not be deleted.

  Also, list of keys could be passed to make transaction-like call. Be aware,
  that: (1) in this case keys and fun arguments are swaped (list must be given
  as a third argument); (2) function given as argument should return list of
  updated states (of the same size).

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the multiagent executes the function and
  returns the result value, or the atom `:infinity` to wait indefinitely. If no
  result is received within the specified time, the function call fails and the
  caller exits. See `flush/2` if queue clean for state is needed.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link( key: fn -> 42 end)
      iex> MultiAgent.update( pid, :key, & 1 + &1)
      :ok
      iex> MultiAgent.get( pid, :key, & &1)
      43

      iex> MultiAgent.update( pid, :otherkey, fn nil -> 42 end)
      :ok
      iex> MultiAgent.get( pid, :othekey, & &1)
      42
  """
  def update( multiagent, _, _, timeout \\ 5000)

  @spec update( multiagent, fun_arg, [key], timeout) :: :ok
  def update( multiagent, fun, keys, timeout) when is_list( keys) do
    GenServer.call( multiagent, {:update, fun, keys}, timeout)
  end

  @spec update( multiagent, key, fun_arg, timeout) :: :ok
  def update( multiagent, key, fun, timeout) do
    GenServer.call( multiagent, {:update, key, fun}, timeout)
  end


  @doc """
  Performs a cast (*fire and forget*) operation on the agent state.

  The function `fun` is sent to the `multiagent` which invokes the
  function passing the multiagent state with given key. The return
  value of `fun` becomes the new state of the multiagent.

  Note that `cast` returns `:ok` immediately, regardless of whether
  `multiagent` (or the node it should live on) exists.
  """
  @spec cast( multiagent, fun_arg, [key]) :: :ok
  def cast( multiagent, fun, keys) when is_list( keys) do
    GenServer.cast( multiagent, {:update, fun, keys})
  end

  @spec cast( multiagent, key, fun_arg) :: :ok
  def cast( multiagent, key, fun) do
    GenServer.cast( multiagent, {:update, key, fun})
  end

  @doc """
  Synchronously stops the multiagent with the given `reason`.

  It returns `:ok` if the multiagent terminates with the given
  reason. If the multiagent terminates with another reason, the call
  will exit.

  This function keeps OTP semantics regarding error reporting.
  If the reason is any other than `:normal`, `:shutdown` or
  `{:shutdown, _}`, an error report will be logged.

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

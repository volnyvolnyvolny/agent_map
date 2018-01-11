defmodule MultiAgent do
  @moduledoc """
  MultiAgents are a simple abstraction around **group** of states.
  Often in Elixir there is a need to share or store states that
  must be accessed from different processes or by the same process
  at different points in time. There are two main solutions: (1) use
  a group of `Agent`s; or (2) a `GenServer`/`Agent` that hold states
  in list/set or some key-value storage and provides parallel access
  for different states. The `MultiAgent` module follows the latter
  approach. It stores states in ETS-table and provides a basic server
  implementation that allows states to be retrieved and updated via
  an API similar to the `Agent` module one.

  ## Examples

  For example, let us manage tasks and projects. Each task can be in
  `:added`, `:started` or `:done` states. This is easy to implement
  with a `MultiAgent`:

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

  The multiagent's states will be added to the given list of arguments (`[%{}]`) as
  the first argument.
  """

  @typedoc "Return values of `start*` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid} | term}

  @typedoc "The multiagent name"
  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "The multiagent reference"
  @type multiagent :: pid | {atom, node} | name

  @typedoc "The multiagent state"
  @type state :: term

  @typedoc "{module, function, arguments}"
  @type mfa :: {module, atom, [any]}


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
        start: Macro.escape( opts[:start]) || quote( do: {__MODULE__, :start_link, [tuples]}),
        restart: opts[:restart] || :permanent,
        shutdown: opts[:shutdown] || 5000,
        type: :worker
      ]

      @doc false
      def child_spec( tuples) do
        %{unquote_splicing( spec)}
      end

      defoverridable child_spec: 1
    end
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

      iex> {:ok, pid} = MultiAgent.start_link( id: fn -> 42 end)
      iex> MultiAgent.get( pid, :id, & &1)
      42
      iex> MultiAgent.get( pid, :errorid, & &1)
      nil

      iex> MultiAgent.start_link( [{:id1, fn -> :timer.sleep( 250) end},
                                   {:id2, fn -> :timer.sleep( 600) end}],
                                  timeout: 500)
      {:error, :timeout}

      iex> {:ok, pid} = MultiAgent.start_link( [], name: :multiagent)
      iex> MultiAgent.start_link( [], name: :multiagent)
      {:error, {:already_started, pid}}

      iex> MultiAgent.start_link( id: fn -> 42 end,
                                  id: fn -> 43 end)
      {:error, {:duplicated, [:id]}}
  """
  @spec start_link( keyword((() -> term) | mfa), GenServer.options) :: on_start
  def start_link( tuples \\ [], options \\ []) do
    GenServer.start_link( MultiAgent.Server, tuples, options)
  end

  @doc """
  Starts an multiagent process without links (outside of
  a supervision tree).

  See `start_link/2` for more information.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start( id: fn -> 42 end)
      iex> MultiAgent.get( pid, :id, & &1)
      42
      iex> {:error, {:badarith, _}} = MultiAgent.start( id: fn -> 1/0 end)
  """
  @spec start( keyword((() -> term) | mfa), GenServer.options) :: on_start
  def start( tuples \\ [], options \\ []) do
    GenServer.start( MultiAgent.Server, tuples, options)
  end


  @doc """
  Initialize a multiagent state via the given anonymous function or MFA.
  The function `fun` is sent to the `multiagent` which invokes it.
  Its return value is used as the multiagent state with given id.
  Note that `init/4` does not return until the given function has
  returned.

  `timeout` is an integer greater than zero which specifies how many
  number of milliseconds multiagent is allowed to spend on
  initialization or it will be terminated and this function will
  return `{:error, :timeout}`. Also, the atom `:infinity` can be
  provided to make multiagent wait indefinitely.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link()
      iex> MultiAgent.get( pid, :id, & &1)
      nil
      iex> MultiAgent.init( pid, :id, fn -> 42 end)
      42
      iex> MultiAgent.get( pid, :id, & &1)
      42

      iex> MultiAgent.init( pid, :id, fn -> 43 end)
      {:error, :already}

      iex> MultiAgent.init( pid, :id, fn -> :timer.sleep( 300) end, 200)
      {:error, :already}
      iex> MultiAgent.init( pid, :otherid, fn -> :timer.sleep( 300) end, 200)
      {:error, :timeout}
  """
  @spec init( multiagent, term, (() -> term), timeout) :: a when a: var
                                                     | {:error, :timeout | :already}
  def init( multiagent, id, fun, timeout \\ 5000) when is_function( fun, 0) do
    GenServer.call( multiagent, {:init, id, fun}, timeout)
  end

  @doc """
  Initialize a multiagent state with given id via the given MFA. See, `init/4`.
  """
  @spec init( multiagent, term, module, atom, [any], timeout) :: a when a: var
                                                            | {:error, :timeout | :already}
  def init( multiagent, id, module, fun, args, timeout \\ 5000) do
    GenServer.call( multiagent, {:init, id, {module, fun, args}}, timeout)
  end


  @doc """
  Gets the multiagent state with given id. The function `fun` is sent to the
  `multiagent` which invokes the function passing the multiagent state. The
  result of the function invocation is returned from this function.

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the multiagent executes the function and returns
  the result value, or the atom `:infinity` to wait indefinitely. If no result
  is received within the specified time, the function call fails and the caller
  exits.

  If there is no state with such id, `nil` will be passed to fun.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link()
      iex> MultiAgent.get( pid, :id, & &1)
      nil
      iex> MultiAgent.init( pid, :id, fn -> 42 end)
      42
      iex> MultiAgent.get( pid, :id, & &1)
      42

      iex> MultiAgent.get( pid, :id, & 1+&1)
      43
  """
  @spec get( multiagent, term, (state -> a), timeout) :: a when a: var
  def get( multiagent, id, fun, timeout \\ 5000) when is_function( fun, 1) do
    GenServer.call( multiagent, {:get, id, fun}, timeout)
  end

  @doc """
  Gets a multiagent value via the given function.
  Same as `get/4` but a module, function, and arguments are expected
  instead of an anonymous function. The state is added as first
  argument to the given list of arguments.
  """
  @spec get( multiagent, term, module, atom, [term], timeout) :: any
  def get( multiagent, id, module, fun, args, timeout \\ 5000) do
    GenServer.call( multiagent, {:get, id, {module, fun, args}}, timeout)
  end


  @doc """
  Gets and updates the multiagent state in one operation via the given
  anonymous function.

  The function `fun` is sent to the `multiagent` which invokes the function
  passing the multiagent state. The function must return a tuple with two
  elements, the first being the value to return (that is, the "get" value)
  and the second one being the new state of the multiagent.

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the multiagent executes the function and
  returns the result value, or the atom `:infinity` to wait indefinitely. If no
  result is received within the specified time, the function call fails and the
  caller exits.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link( id: fn -> 42 end)
      iex> MultiAgent.get_and_update( pid, :id, & {&1, &1 + 1})
      42
      iex> MultiAgent.get( pid, :id, & &1)
      43
  """
  @spec get_and_update( multiagent, term, (state -> {a, state}), timeout) :: a when a: var
  def get_and_update( multiagent, id, fun, timeout \\ 5000) when is_function( fun, 1) do
    GenServer.call( multiagent, {:get_and_update, id, fun}, timeout)
  end

  @doc """
  Gets and updates the multiagent state in one operation via the given function.
  Same as `get_and_update/4` but a module, function, and arguments are expected
  instead of an anonymous function. The state is added as first argument to the
  given list of arguments.
  """
  @spec get_and_update( multiagent, term, module, atom, [term], timeout) :: any
  def get_and_update( multiagent, id, module, fun, args, timeout \\ 5000) do
    GenServer.call( multiagent, {:get_and_update, id, {module, fun, args}}, timeout)
  end


  @doc """
  Updates the agent state via the given anonymous function.

  The function `fun` is sent to the `multiagent` which invokes the function
  passing the multiagent state. The return value of `fun` becomes the new
  state of the multiagent.

  This function always returns `:ok`.

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the multiagent executes the function and
  returns the result value, or the atom `:infinity` to wait indefinitely. If no
  result is received within the specified time, the function call fails and the
  caller exits.

  ## Examples

      iex> {:ok, pid} = MultiAgent.start_link( id: fn -> 42 end)
      iex> MultiAgent.update( pid, :id, & 1 + &1)
      :ok
      iex> MultiAgent.get( pid, :id, & &1)
      43

      iex> MultiAgent.update( pid, :otherid, fn nil -> 42 end)
      :ok
      iex> MultiAgent.get( pid, :otherid, & &1)
      42
  """
  @spec update( multiagent, term, (state -> state), timeout) :: :ok
  def update( multiagent, id, fun, timeout \\ 5000) when is_function( fun, 1) do
    GenServer.call( multiagent, {:update, id, fun}, timeout)
  end

  @doc """
  Updates the agent state via the given function.
  Same as `update/4 but a module, function, and arguments are expected
  instead of an anonymous function. The state is added as first
  argument to the given list of arguments.
  """
  @spec update( multiagent, term, module, atom, [term], timeout) :: :ok
  def update( multiagent, id, module, fun, args, timeout \\ 5000) do
    GenServer.call( multiagent, {:update, id, {module, fun, args}}, timeout)
  end

  @doc """
  Performs a cast (*fire and forget*) operation on the agent state.
  The function `fun` is sent to the `agent` which invokes the function
  passing the agent state. The return value of `fun` becomes the new
  state of the agent.
  Note that `cast` returns `:ok` immediately, regardless of whether `agent` (or
  the node it should live on) exists.
  """
  @spec cast(agent, (state -> state)) :: :ok
  def cast(agent, fun) when is_function(fun, 1) do
    GenServer.cast(agent, {:cast, fun})
  end

  @doc """
  Performs a cast (*fire and forget*) operation on the agent state.
  Same as `cast/2` but a module, function, and arguments are expected
  instead of an anonymous function. The state is added as first
  argument to the given list of arguments.
  """
  @spec cast(agent, module, atom, [term]) :: :ok
  def cast(agent, module, fun, args) do
    GenServer.cast(agent, {:cast, {module, fun, args}})
  end

  @doc """
  Synchronously stops the agent with the given `reason`.
  It returns `:ok` if the agent terminates with the given
  reason. If the agent terminates with another reason, the call will
  exit.
  This function keeps OTP semantics regarding error reporting.
  If the reason is any other than `:normal`, `:shutdown` or
  `{:shutdown, _}`, an error report will be logged.
  ## Examples
      iex> {:ok, pid} = Agent.start_link(fn -> 42 end)
      iex> Agent.stop(pid)
      :ok
  """
  @spec stop(agent, reason :: term, timeout) :: :ok
  def stop(agent, reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop(agent, reason, timeout)
  end
end

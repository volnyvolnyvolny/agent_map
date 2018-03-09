defmodule AgentMap do

  @enforce_keys [:link]
  defstruct @enforce_keys

  @behaviour Access

  alias AgentMap.{Callback, Server, Req}

  import Callback, only: :macros


  @moduledoc """

  `AgentMap` is a `GenServer` that holds `Map` and provides concurrent access
  via `Agent` API for operations made on different keys. Basically, it can be
  used as a cache, memoization framework and, sometimes, `GenServer`
  replacement. `AgentMap` is more like `Map`, each value of that is an `Agent`.

  `AgentMap` stores states in a `Map` and when a changing state callback (see
  `update`, `get_and_update`, `cast` and derivative) comes in, special temporary
  process (called "worker") that stores queue is created. `AgentMap` respects
  order in which callbacks arrives and supports transactions — operations that
  simultaniously change group of states.

  Module API is in fact a copy of the `Agent`'s and `Map`'s modules. Special
  struct that allows to use `Enum` module and `[]` operator can be created via
  `new/1` function.

  In fact, `AgentMap` is at the same time a stateful `Map` and `Agent` that
  holds `Map`.

  ## Example

  Let us create accounting.

      defmodule Billing do
        use AgentMap

        def start_link() do
          AgentMap.start_link name: __MODULE__
        end

        @doc """
        Withdraw. Returns `{:ok, new_amount}` or `:error`.
        """
        def withdraw(account, amount) do
          AgentMap.get_and_update __MODULE__, account, fn
            nil ->
              {:error}
            value when value > amount ->
              {{:ok, value-amount}, value-amount}
            _ ->
              {:error}
          end
        end

        @doc """
        Withdraw. Returns `{:ok, new_amount}` or `:error`.
        """
        def withdraw(account, amount) do
          AgentMap.get_and_update __MODULE__, account, fn
            nil ->
              {:error}
            value when value > amount ->
              {{:ok, value-amount}, value-amount}
            _ ->
              {:error}
          end
        end
      end


  Let us manage tasks and projects. Each task can be in `:added`, `:started` or
  `:done` states. This is easy to do with a `AgentMap`:

      defmodule TasksServer do
        use AgentMap

        def start_link() do
          AgentMap.start_link name: __MODULE__
        end

        @doc "Add new project task"
        def add(project, task) do
          AgentMap.init __MODULE__, {project, task}, fn -> :added end
        end

        @doc "Returns state of given task"
        def state(project, task) do
          AgentMap.get __MODULE__, {project, task}, & &1
        end

        @doc "Returns list of all project tasks"
        def list(project) do
          tasks = AgentMap.keys __MODULE__
          for {^project, task} <- tasks, do: task
        end

        @doc "Returns list of project tasks in given state"
        def list(project, state: state) do
          tasks = AgentMap.keys __MODULE__
          for {^project, task} <- tasks,
              state( project, task) == state, do: task
        end

        @doc "Updates project task"
        def update(project, task, new_state) do
          AgentMap.update __MODULE__, {project, task}, fn _ -> new_state end
        end

        @doc "Deletes given project task, returning state"
        def pop(project, task) do
          AgentMap.pop __MODULE__, {project, task}
        end
      end

  `AgentMap` provide a segregation between the client and server APIs (similar
  to the `GenServer` and `Agent`). In particular, any changing state anonymous
  functions given to the `AgentMap` is executed inside the agentmap (the server)
  and effectively block execution of any other function **on the same state**
  until the request is fulfilled. So it's important to avoid use of expensive
  operations inside the agentmap. See corresponding `Agent` docs section.

  Finally note that `use AgentMap` defines a `child_spec/1` function, allowing
  the defined module to be put under a supervision tree. The generated
  `child_spec/1` can be customized with the following options:

    * `:id` - the child specification id, defauts to the current module
    * `:start` - how to start the child process (defaults to calling `__MODULE__.start_link/1`)
    * `:restart` - when the child should be restarted, defaults to `:permanent`
    * `:shutdown` - how to shut down the child

  For example:

      use AgentMap, restart: :transient, shutdown: 10_000

  See the `Supervisor` docs for more information.


  
  ## Urgent (`:!`) calls

  `AgentMap` supports so-called "urgent" (out of turn calls) for `get`

  ## Batch calls


  
  ## `get`, `get_and_update`, `update`, `cast`

  Every one of this methods has three different forms multiply two for urgent/or
  not calls. For example:

      get agentmap, key1: fn state -> fun.(state) end
                  , key2: fn state -> fun.(state) end

  is `get/2` form used for batch processing.

      get agentmap, :key, fn state -> fun.(state) end

  `get/3`
  
  

  ## Name registration

  An agentmap is bound to the same name registration rules as GenServers. Read
  more about it in the `GenServer` documentation.

  ## A word on distributed agents/agentmaps

  See corresponding `Agent` module section.

  ## Hot code swapping

  A agentmap can have its code hot swapped live by simply passing a module,
  function, and arguments tuple to the update instruction. For example, imagine
  you have a agentmap named `:sample` and you want to convert all its inner
  states from a keyword list to a map. It can be done with the following
  instruction:

      {:update, :sample, {:advanced, {Enum, :into, [%{}]}}}

  The agentmap's states will be added to the given list of arguments
  (`[%{}]`) as the first argument.

  ## Using `Enum` module and `[]`-access operator

  `%AgentMap{}` is a special struct that contains pid of the `agentmap` process
  and for that `Enumerable` protocol is implemented. So, `Enum` should work as
  expected:

      iex> AgentMap.new() |> Enum.empty?()
      true
      iex> AgentMap.new(key: 42) |> Enum.empty?()
      false

  Similarly, `AgentMap` follows `Access` behaviour, so `[]` operator could be
  used:

      iex> AgentMap.new(a: 42, b: 24)[:a]
      42

  except of `put_in` operator.
  """

  @typedoc "Return values of `start*` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid} | term}

  @typedoc "The agentmap name"
  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "The agentmap reference"
  @type agentmap :: pid | {atom, node} | name | %AgentMap{}

  @typedoc "The agentmap state key"
  @type key :: term

  @typedoc "The agentmap state"
  @type state :: term

  @typedoc "Anonymous function, `{fun, args}` or MFA triplet"
  @type fun_arg(a, r) :: (a -> r) | {(... -> r), [a | any]} | {module, atom, [a | any]}

  @typedoc "Anonymous function with zero arity, pair `{fun/length(args), args}` or corresponding MFA tuple"
  @type fun_arg(r) :: (() -> r) | {(... -> r), [any]} | {module, atom, [any]}




  @doc false
  def child_spec( funs_and_opts) do
    %{id: AgentMap,
      start: {AgentMap, :start_link, [funs_and_opts]}}
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

        Supervisor.child_spec default, unquote(Macro.escape opts)
      end

      defoverridable child_spec: 1
    end
  end


  ## HELPERS ##

  defp pid(%__MODULE__{link: mag}), do: mag
  defp pid(mag), do: mag


  defguardp is_timeout(t) when t == :infinity or is_integer(t) and t >= 0

  defp batch(mag, req, timeout \\ nil) do
    mag = pid(mag)
    results =
      Enum.map(req.data, &Task.async fn ->
        req = %{req | data: &1}
        case req do
          %{action: :get, !: true} ->
            GenServer.call mag, req, timeout
          %{action: :cast} ->
            GenServer.cast mag, req
          _ ->
            GenServer.call mag, req, timeout
        end
      end) |>
      Task.yield_many(timeout) |>
      Enum.map(fn {task, res} ->
        case res || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          exit ->
            Process.exit(self(), exit || :timeout)
        end
      end)

    if req.action in [:update, :cast], do: :ok, else: results
  end


  ## ##


  # common for start_link and start
  defp separate(funs_and_opts) do
    {opts, funs} =
      Enum.reverse(funs_and_opts) |>
      Enum.split_while(fn {_,v} -> not fun?(v,0) end)

    {Enum.reverse(funs), opts}
  end


  @doc """
  Returns a new empty `agentmap`.

  ## Examples

      iex> mag = AgentMap.new()
      iex> Enum.empty? mag
      true
  """
  @spec new :: agentmap
  def new, do: new %{}


  @doc """
  Starts an `AgentMap` via `start_link/1` function. `new/1` returns
  `AgentMap` **struct** that contains pid of the `AgentMap`.

  As the only argument, states keyword can be provided or already started
  agentmap.

  ## Examples

      iex> mag = AgentMap.new a: 42, b: 24
      iex> mag[:a]
      42
      iex> AgentMap.keys mag
      [:a, :b]

      iex> {:ok, pid} = AgentMap.start_link()
      iex> mag = AgentMap.new pid
      iex> AgentMap.put mag, :a, 1
      iex> mag[:a]
      1
  """
  @spec new(Enumerable.t() | agentmap) :: agentmap
  def new(enumerable)

  def new(%__MODULE__{}=mag), do: mag
  def new(%_{} = struct), do: new Map.new struct
  def new(list) when is_list(list), do: new Map.new list
  def new(%{} = states) when is_map(states) do
    states = for {key, state} <- states do
      {key, fn -> state end}
    end

    {:ok, mag} = start_link states
    new mag
  end
  def new(mag), do: %__MODULE__{link: GenServer.whereis mag}


  @doc """
  Creates an agentmap from an `enumerable` via the given transformation
  function. Duplicated keys are removed; the latest one prevails.

  ## Examples

      iex> mag = AgentMap.new [:a, :b], fn x -> {x, x} end
      iex> AgentMap.take mag, [:a, :b]
      %{a: :a, b: :b}
  """
  @spec new(Enumerable.t(), (term -> {key, state})) :: agentmap
  def new(enumerable, transform) do
    new Map.new( enumerable, transform)
  end


  @doc """
  Starts an agentmap linked to the current process with the given function.
  This is often used to start the agentmap as part of a supervision tree.

  The first argument is a list of pairs `{term, fun_arg}` (keyword, in
  particular). The second element of each pair is an anonymous function, `{fun,
  args}` or MFA-tuple with zero num of arguments.

  For each key, callback is executed as a separate `Task`.

  ## Options

  The `:name` option is used for registration as described in the module
  documentation.

  If the `:timeout` option is present, the agentmap is allowed to spend at
  most the given number of milliseconds on the whole process of initialization
  or it will be terminated and the start function will return `{:error,
  :timeout}`.

  If the `:debug` option is present, the corresponding function in the
  [`:sys` module](http://www.erlang.org/doc/man/sys.html) will be invoked.

  If the `:spawn_opt` option is present, its value will be passed as options
  to the underlying process as in `Process.spawn/4`.

  ## Return values

  If the server is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a agentmap with the
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

      iex> {:ok, pid} = AgentMap.start_link key: fn -> 42 end
      iex> AgentMap.get pid, :key, & &1
      42
      iex> AgentMap.get pid, :nosuchkey, & &1
      nil
  """
  @spec start_link([{key, fun_arg(any)} | GenServer.option]) :: on_start
  def start_link(funs_and_opts \\ [timeout: 5000]) do
    {funs, opts} = separate funs_and_opts
    timeout = opts[:timeout] || 5000
    opts = Keyword.put(opts, :timeout, :infinity) # turn off global timeout
    GenServer.start_link Server, {funs, timeout}, opts
  end


  @doc """
  Starts an agentmap unlinked process.

  See `start_link/2` for details.

  ## Examples

      iex> AgentMap.start one: 42,
      ...>                two: fn -> :timer.sleep(150) end,
      ...>                three: fn -> :timer.sleep(:infinity) end,
      ...>                timeout: 100
      {:error, [one: :cannot_call, two: :timeout, three: :timeout]}

      iex> AgentMap.start one: :foo,
      ...>                one: :bar,
      ...>                three: fn -> :timer.sleep(:infinity) end,
      ...>                timeout: 100
      {:error, [one: :already_exists]}

      iex> err = AgentMap.start one: 76, two: fn -> raise "oops" end
      iex> {:error, [one: :cannot_call, two: {exception, _stacktrace}]} = err
      iex> exception
      %RuntimeError{message: "oops"}
  """
  @spec start([{key, fun_arg(any)} | GenServer.option]) :: on_start
  def start(funs_and_opts \\ [timeout: 5000]) do
    {funs, opts} = separate funs_and_opts
    timeout = opts[:timeout] || 5000
    opts = Keyword.put(opts, :timeout, :infinity) # turn off global timeout
    GenServer.start Server, {funs, timeout}, opts
  end


  defp fun?(fun, arity) when is_fun(fun, arity), do: true
  defp fun?(_, _), do: false


  @doc """
  Gets the agentmap state with given key. The callback `fun` will be sent to
  the `agentmap`, which will add it to the execution queue for the given key.
  Before the invocation, the agentmap state will be passed as the first
  argument. If `agentmap` has no state with such key, `nil` will be passed to
  `fun`. The result of the `fun` invocation is returned from this function.

  Also, list of keys could be passed to make aggregate function calls:

      get accounts, &Enum.sum/1, [:alice, :bob]

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the agentmap executes the callback and returns
  the result value, or the atom `:infinity` to wait indefinitely. If no result
  is received within the specified time, the function call fails and the caller
  exits.

  ## Examples

      iex> mag = AgentMap.new()
      iex> AgentMap.get mag, :alice, & &1
      nil
      iex> AgentMap.put mag, :alice, 42
      iex> AgentMap.get mag, :alice, & &1+1
      43
      #
      # aggregate calls:
      #
      iex> AgentMap.put mag, :bob, 43
      iex> AgentMap.get mag, &Enum.sum/1, [:alice, :bob]
      85
      # order matters:
      iex> AgentMap.get mag, {&Enum.reduce/3, [0, &-/2]}, [:alice, :bob]
      1
      iex> AgentMap.get mag, {&Enum.reduce/3, [0, &-/2]}, [:bob, :alice]
      -1

  ## Urgent (`:!`)

  Urgent version of `get` can be used to make out of turn async call. State can
  have an associated queue of callbacks, waiting to be executed. This version
  works as `get`, but retrives state immediately at the moment of call. No
  matter of current number of threads used for involved state(s) it is called in
  a separate `Task`.

  ## Examples

      iex> mag = AgentMap.new key: 42
      iex> AgentMap.cast mag, :key, fn _ ->
      ...>   :timer.sleep( 100)
      ...>   43
      ...> end
      iex> AgentMap.get mag, :!, :key, & &1
      42
      iex> mag[:key] # the same
      42
      iex> AgentMap.get mag, :key, & &1
      43
      iex> AgentMap.get mag, :!, :key, & &1
      43
  """
  @spec get(agentmap, :!, fun_arg([state], a), [key], timeout) :: a when a: var
  @spec get(agentmap, :!, key, fun_arg(state, a), timeout) :: a when a: var

  # 5
  def get(agentmap, :!, fun, keys, timeout) when is_fun(fun, 1) and is_list(keys) do
    mag = pid agentmap
    GenServer.call mag, %Req{!: true, action: :get, data: {fun,keys}}, timeout
  end
  def get(agentmap, :!, key, fun, timeout) when is_fun(fun, 1) do
    mag = pid agentmap
    GenServer.call mag, %Req{!: true, action: :get, data: {key,fun}}, timeout
  end


  @doc """
  See `get/5`.
  """
  @spec get(agentmap, :!, timeout, [{key, fun_arg(state, any)}]) :: [any]
  @spec get(agentmap, :!, fun_arg([state], a), [key]) :: a when a: var
  @spec get(agentmap, :!, key, fun_arg(state, a)) :: a when a: var

  @spec get(agentmap, fun_arg([state], a), [key], timeout) :: a when a: var
  @spec get(agentmap, key, fun_arg(state, a), timeout) :: a when a: var

  # 4
  def get(agentmap, :!, timeout, funs) when is_timeout(timeout) and is_list(funs) do
    batch agentmap, %Req{!: true, action: :get, data: funs}, timeout
  end
  def get(agentmap, :!, fun, keys) when is_fun(fun,1) and is_list(keys) do
    get agentmap, :!, fun, keys, 5000
  end
  def get(agentmap, :!, key, fun) when is_fun(fun,1) do
    get agentmap, :!, key, fun, 5000
  end

  def get(agentmap, fun, keys, timeout) when is_fun(fun,1) and is_list(keys) and is_timeout(timeout) do
    mag = pid agentmap
    GenServer.call mag, %Req{action: :get, data: {fun,keys}}, timeout
  end
  def get(agentmap, key, fun, timeout) when is_fun(fun,1) and is_timeout(timeout) do
    mag = pid(agentmap)
    GenServer.call mag, %Req{action: :get,
                             data: {key,fun}}, timeout
  end

  @spec get(agentmap, fun_arg([state], a), [key]) :: a when a: var
  @spec get(agentmap, key, fun_arg(state, a)) :: a when a: var
  @spec get(agentmap, :!, [{key, fun_arg(state, any)}]) :: [any]
  @spec get(agentmap, timeout, [{key, fun_arg(state, any)}]) :: [any]
  @spec get(agentmap, key, fun_arg(state, a) | a) :: state | a when a: var

  # 3
  def get(agentmap, key, default)

  def get(agentmap, :!, funs) when is_list(funs) do
    get agentmap, :!, 5000, funs
  end
  def get(agentmap, timeout, funs) when is_timeout(timeout) and is_list(funs) do
    batch agentmap, %Req{action: :get, data: funs}, timeout
  end

  def get(agentmap, fun, keys) when is_fun(fun,1) and is_list(keys) do
    get agentmap, fun, keys, 5000
  end

  def get(agentmap, key, fun) when is_fun(fun,1) do
    get agentmap, key, fun, 5000
  end

  # Say hi to Access behaviour!
  def get(agentmap, key, default) do
    GenServer.call pid(agentmap), {:!, {:get, key, default}}
  end


  @doc """
  Version of `get/5` to be used for batch processing. As in `get/5`, urgent
  (`:!`) mark can be provided to make out of turn call.

  See also `get_and_update/2`, `update/2` and `cast/2`.

  ## Examples

      iex> mag = AgentMap.new()
      iex> AgentMap.get mag, alice: & &1, bob: & &1
      [nil, nil]
      iex> AgentMap.update mag, alice: fn nil -> 42 end,
      ...>                      bob:   fn nil -> 24 end
      :ok
      iex> AgentMap.get mag, alice: & &1, bob: & &1
      [42, 24]
      iex> AgentMap.update mag, alice: & &1-10, bob: & &1+10
      iex> AgentMap.get mag, alice: & &1, bob: & &1
      [32, 34]
  """
  @spec get(agentmap, [{key, fun_arg(state, any)}]) :: [any]
  def get(agentmap, funs) when is_list(funs) do
    if Enum.any? funs, fn {_k,f} -> !fun?(f,1) end do
      key = funs # ambiguity fix
      get agentmap, key, nil
    else
      get agentmap, 5000, funs
    end
  end

  @spec get(agentmap, key) :: state | nil
  def get(agentmap, key), do: get agentmap, key, nil


  @doc """
  Gets and updates the agentmap state with given key in one operation. The
  callback `fun` will be sent to the `agentmap`, which will add it to the
  execution queue for then given key. Before the invocation, the agentmap
  state will be passed as the first argument. If `agentmap` has no state with
  such key, `nil` will be passed to the `fun`. The function must return a tuple
  with two elements, the first being the value to return (that is, the "get"
  value) and the second one being the new state.

  Callback may also return `:pop`. Similar to `Map.get_and_update/3` it returns
  state with given key and removes it from `agentmap`.

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

      get_and_update agentmap, fn [a, b] ->
        if a > 10 do
          a = a-10
          b = b+10
          [{a,a}, {b,b}] # [{get, new_state}]
        else
          {{:error, "Alice does not have 10$ to give to Bob!"}, [a,b]} # {get, [new_state]}
        end
      end, [:alice, :bob]

  Please notice that in this case keys and fun arguments are swaped (list must
  be given as the third argument). This follows from fact that `agentmap` do
  not impose any restriction on the key type: anything can be a key in a
  `agentmap`, even a list. So it could not be detected if its a key or a list
  of keys.

  Callback must return list of `{get, new_state} | :id | :pop`, where `:pop` and
  `:id` make keys states to be returned as it is, and `:pop` will make the state
  be removed:

      iex> mag = AgentMap.new alice: 42, bob: 24
      iex> AgentMap.get_and_update mag, fn _ -> [:pop, :id] end, [:alice, :bob]
      [42, 24]
      iex> AgentMap.get mag, & &1, [:alice, :bob]
      [nil, 24]

  Also, as in the error statement of previous example, callback may return pair
  `{get, [new_state]}`. This way aggregated value will be returned and all the
  corresponding states will be updated.

  And finally, callback may return `:pop` to return and remove all given states.

  (!) State changing transaction (such as `get_and_update`) will block all the
  involved states queues until the end of execution. So, for example,

      iex> AgentMap.new( alice: 42, bob: 24, chris: 0) |>
      ...> AgentMap.get_and_update(&:timer.sleep(1000) && {:slept_well, &1}, [:alice, :bob])
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
  milliseconds are allowed before the agentmap executes the function and
  returns the result value, or the atom `:infinity` to wait indefinitely. If no
  result is received within the specified time, the function call fails and the
  caller exits. If this happened but callback is so far in the queue, and in
  `init/4` call `:late_call` flag is set to true, it will still be executed.

  ## Examples

      iex> import AgentMap
      iex> mag = new uno: 22, dos: 24, tres: 42, cuatro: 44
      iex> get_and_update mag, :uno, & {&1, &1 + 1}
      22
      iex> get mag, :uno, & &1
      23
      #
      iex> get_and_update mag, :tres, fn _ -> :pop end
      42
      iex> get mag, :tres, & &1
      nil
      #
      # transaction calls:
      #
      iex> get_and_update mag, fn [u, d] ->
      ...>   [{u, d}, {d, u}]
      ...> end, [:uno, :dos]
      [23, 24]
      iex> get mag, & &1, [:uno, :dos]
      [24, 23]
      #
      iex> get_and_update mag, fn _ -> :pop end, [:dos]
      [23]
      iex> get mag, & &1, [:uno, :dos, :tres, :cuatro]
      [24, nil, nil, 44]
      #
      iex> get_and_update mag, fn _ ->
      ...>   [:id, {nil, :_}, {:_, nil}, :pop]
      ...> end, [:uno, :dos, :tres, :cuatro]
      [24, nil, :_, 44]
      iex> get mag, & &1, [:uno, :dos, :tres, :cuatro]
      [24, :_, nil, nil]
  """
  # 5
  @spec get_and_update(agentmap, :!, fun_arg([state], [{any} | {any, state} | :pop | :id]), [key], timeout)
        :: [any | state]
  @spec get_and_update(agentmap, :!, fun_arg([state], {a, [state] | :pop}), [key], timeout)
        :: a when a: var
  @spec get_and_update(agentmap, :!, fun_arg([state], :pop), [key], timeout)
        :: [state]

  def get_and_update(agentmap, :!, fun, keys, timeout) when is_fun(fun,1) and is_list(keys) and is_timeout(timeout) do
    mag = pid agentmap
    GenServer.call mag, %Req{!: true,
                             action: :get_and_update,
                             data: {fun,keys}}, timeout
  end

  @spec get_and_update(agentmap, :!, key, fun_arg(state, {a} | {a, state} | :pop), timeout)
        :: a | state when a: var
  def get_and_update(agentmap, :!, key, fun, timeout) when is_fun(fun,1) and is_timeout(timeout) do
    mag = pid agentmap
    GenServer.call mag, %Req{!: true,
                             action: :get_and_update,
                             data: {key,fun}}, timeout
  end

  #4
  @spec get_and_update(agentmap, :!, fun_arg([state], [{any} | {any, state} | :pop | :id]), [key])
        :: [any | state]
  @spec get_and_update(agentmap, :!, fun_arg([state], {a, [state] | :drop}), [key])
        :: a when a: var
  @spec get_and_update(agentmap, :!, fun_arg([state], :pop), [key])
        :: [state]

  def get_and_update(agentmap, :!, fun, keys) when is_fun(fun,1) and is_list(keys) do
    get_and_update agentmap, :!, fun, keys, 5000
  end


  @spec get_and_update(agentmap, :!, key, fun_arg(state, {a} | {a, state} | :pop))
        :: a | state when a: var
  def get_and_update(agentmap, :!, key, fun) when is_fun(fun,1) do
    get_and_update agentmap, :!, key, fun, 5000
  end

  #

  @spec get_and_update(agentmap, fun_arg([state], [{any} | {any, state} | :pop | :id]), [key], timeout)
        :: [any | state]
  @spec get_and_update(agentmap, fun_arg([state], {a, [state] | :drop}), [key], timeout)
        :: a when a: var
  @spec get_and_update(agentmap, fun_arg([state], :pop), [key], timeout)
        :: [state]

  def get_and_update(agentmap, fun, keys, timeout) when is_fun(fun,1) and is_list(keys) and is_timeout(timeout) do
    mag = pid(agentmap)
    GenServer.call mag, %Req{action: :get_and_update,
                             data: {fun,keys}}, timeout
  end

  @spec get_and_update(agentmap, key, fun_arg(state, {a} | {a, state} | :pop), timeout)
        :: a | state when a: var
  def get_and_update(agentmap, key, fun, timeout) when is_fun(fun,1) and is_timeout(timeout) do
    mag = pid agentmap
    GenServer.call mag, %Req{action: :get_and_update,
                             data: {key,fun}}, timeout
  end


  @spec get_and_update(agentmap, :!, timeout, [{key, fun_arg(state, {any} | {any, state} | :pop)}])
        :: [state | any]
  def get_and_update(agentmap, :!, timeout, funs) when is_timeout(timeout) do
    req = %Req{!: true, action: :get, data: funs}
    batch agentmap, req, timeout
  end

  # 3
  @doc """
  Version of `get_and_update/5` to be used for batch processing. As in
  `get_and_update/5`, urgent (`:!`) mark can be provided to make out of turn
  call. Works the same as `get/4`, `update/4`.
  """

  @spec get_and_update(agentmap, fun_arg([state], [{any} | {any, state} | :pop | :id]), [key])
        :: [any | state]
  @spec get_and_update(agentmap, fun_arg([state], {a, [state] | :drop}), [key])
        :: a when a: var
  @spec get_and_update(agentmap, fun_arg([state], :pop), [key])
        :: [state]

  def get_and_update(agentmap, fun, keys) when is_fun(fun,1) and is_list(keys) do
    get_and_update agentmap, fun, keys, 5000
  end

  @spec get_and_update(agentmap, key, fun_arg(state, {a} | {a, state} | :pop))
        :: a | state when a: var
  def get_and_update(agentmap, key, fun) when is_fun(fun,1) do
    get_and_update agentmap, key, fun, 5000
  end


  @spec get_and_update(agentmap, :!, [{key, fun_arg(state, {any} | {any, state} | :pop)}])
        :: [state | any]
  def get_and_update(agentmap, :!, funs) do
    get_and_update agentmap, :!, 5000, funs
  end

  @spec get_and_update(agentmap, timeout, [{key, fun_arg(state, {any} | {any, state} | :pop)}])
        :: [state | any]
  def get_and_update(agentmap, timeout, funs) when is_timeout(timeout) do
    req = %Req{action: :get_and_update, data: funs}
    batch agentmap, req, timeout
  end

  # 2

  @spec get_and_update(agentmap, [{key, fun_arg(state, {any} | {any, state} | :pop)}])
        :: [state | any]
  def get_and_update(agentmap, funs) do
    get_and_update agentmap, 5000, funs
  end


  @doc """
  Updates agentmap state with given key. The callback `fun` will be sent to
  the `agentmap`, which will add it to the execution queue for the given key
  state. Before the invocation, the agentmap state will be passed as the first
  argument. If `agentmap` has no state with such key, `nil` will be passed to
  `fun`. The return value of callback becomes the new state of the agentmap.

  Be aware that: (1) this function always returns `:ok`; (2) anonymous function,
  `{fun, args}` or MFA tuple can be passed as a callback; (3) every state has
  it's own FIFO queue of callbacks waiting for execution and queues for
  different states are processed in parallel.

  ## Transaction calls

  Transaction (group) call could be made by passing list of keys and callback
  that takes list of states with given keys and returns list of new states. See
  corresponding `get/5` docs section.

  Callback must return list of new states or `:drop` to remove all given states:

      iex> mag = AgentMap.new alice: 42, bob: 24, chris: 33, dunya: 51
      iex> AgentMap.update mag, &Enum.reverse/1, [:alice, :bob]
      :ok
      iex> AgentMap.get mag, & &1, [:alice, :bob]
      [24, 42]
      iex> AgentMap.update mag, fn _ -> :drop end, [:alice, :bob]
      iex> AgentMap.keys mag
      [:chris, :dunya]
      iex> AgentMap.update mag, fn _ -> :drop end, [:chris]
      iex> AgentMap.update mag, :dunya, fn _ -> :drop end
      iex> AgentMap.get mag, & &1, [:chris, :dunya]
      [nil, :drop]

  (!) State changing transaction (such as `update`) will block all the involved
  states queues until the end of execution. So, for example,

      iex> AgentMap.new( alice: 42, bob: 24, chris: 0) |>
      ...> AgentMap.update( fn _ ->
      ...>   :timer.sleep(1000)
      ...>   :drop
      ...> end, [:alice, :bob])
      :ok

  will block the possibility to `get_and_update`, `update`, `cast` and even
  `get` `:alice` and `:bob` states for 1 sec. Nonetheless states are always
  available for "urgent" `get` calls and `:chris` state is not blocked.

  ## Timeout

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the agentmap executes the function and
  returns the result value, or the atom `:infinity` to wait indefinitely. If no
  result is received within the specified time, the function call fails and the
  caller exits. If this happened but callback is so far in the queue, and in
  `init/4` call `:late_call` option was set to true (by def.), it will still be
  executed.

  ## Examples

      iex> {:ok, pid} = AgentMap.start_link key: fn -> 42 end
      iex> AgentMap.update pid, :key, & &1+1
      :ok
      iex> AgentMap.get pid, :key, & &1
      43
      #
      iex> AgentMap.update pid, :otherkey, fn nil -> 42 end
      :ok
      iex> AgentMap.get pid, :otherkey, & &1
      42
  """
  # 5
  @spec update(agentmap, :!, fun_arg([state], [state] | :drop), [key], timeout) :: :ok
  def update(agentmap, :!, fun, keys, timeout) when is_fun(fun,1) and is_list(keys) and is_timeout(timeout) do
    GenServer.call pid(agentmap), %Req{!: true,
                                       action: :update,
                                       data: {fun,keys}}, timeout
  end

  @spec update(agentmap, :!, key, fun_arg(state, state), timeout) :: :ok
  def update(agentmap, :!, key, fun, timeout) when is_fun(fun,1) and is_timeout(timeout) do
    GenServer.call pid(agentmap), %Req{!: true,
                                       action: :update,
                                       data: {key,fun}}, timeout
  end

  # 4
  @spec update(agentmap, :!, fun_arg([state], [state] | :drop), [key]) :: :ok
  def update(agentmap, :!, fun, keys) when is_fun(fun,1) and is_list(keys) do
    update agentmap, :!, fun, keys, 5000
  end


  @spec update(agentmap, :!, key, fun_arg(state, state)) :: :ok
  def update(agentmap, :!, key, fun) when is_fun(fun,1) do
    update agentmap, :!, key, fun, 5000
  end

  #

  @spec update(agentmap, fun_arg([state], [state] | :drop), [key], timeout) :: :ok
  def update(agentmap, fun, keys, timeout) when is_fun(fun,1) and is_list(keys) and is_timeout(timeout) do
    GenServer.call pid(agentmap), %Req{action: :update,
                                       data: {fun,keys}}, timeout
  end

  @spec update(agentmap, key, fun_arg(state, state), timeout) :: :ok
  def update(agentmap, key, fun, timeout) when is_fun(fun,1) and is_timeout(timeout) do
    GenServer.call pid(agentmap), %Req{action: :update,
                                       data: {key,fun}}, timeout
  end

  @spec update(agentmap, :!, timeout, [{key, fun_arg(state, state)}]) :: :ok
  def update(agentmap, :!, timeout, funs) when is_timeout(timeout) do
    req = %Req{!: true, action: :update, data: funs}
    batch agentmap, req, timeout
  end

  # 3

  @doc """
  Version of `get_and_update/5` to be used for batch processing. As in
  `get_and_update/5`, urgent (`:!`) mark can be provided to make out of turn
  call. Works the same as `get/4`, `update/4`.
  """

  @spec update(agentmap, fun_arg([state], [state] | :drop), [key]) :: :ok
  def update(agentmap, fun, keys) when is_fun(fun,1) and is_list(keys) do
    update agentmap, fun, keys, 5000
  end

  @spec update(agentmap, key, fun_arg(state, state)) :: :ok
  def update(agentmap, key, fun) when is_fun(fun,1) do
    update agentmap, key, fun, 5000
  end


  @spec update(agentmap, :!, [{key, fun_arg(state, state)}]) :: :ok
  def update(agentmap, :!, funs) do
    update agentmap, :!, 5000, funs
  end

  @doc """
  Version of `update/5` to be used for batch processing. As in `update/5`,
  urgent (`:!`) mark can be provided to make out of turn call. Works the same as
  `get/4` and `get_and_update/4`.
  """
  @spec update(agentmap, timeout, [{key, fun_arg(state, state)}]) :: :ok
  def update(agentmap, timeout, funs) when is_timeout(timeout) do
    req = %Req{action: :update, data: funs}
    batch agentmap, req, timeout
  end

  #2

  @spec update(agentmap, [{key, fun_arg(state, state)}]) :: :ok
  def update(agentmap, funs) do
    update agentmap, 5000, funs
  end


  @doc """
  Perform `cast` ("fire and forget") `update`.
  See `update/2` docs.
  """
  # 4
  @spec cast(agentmap, :!, fun_arg([state], [state] | :drop), [key]) :: :ok
  def cast(agentmap, :!, fun, keys) when is_fun(fun,1) and is_list(keys) do
    GenServer.cast pid(agentmap), %Req{!: true,
                                       action: :cast,
                                       data: {fun,keys}}
  end

  @spec cast(agentmap, :!, key, fun_arg(state, state)) :: :ok
  def cast(agentmap, :!, key, fun) when is_fun(fun,1) do
    GenServer.cast pid(agentmap), %Req{!: true,
                                       action: :cast,
                                       data: {key,fun}}
  end

  # 3

  @spec cast(agentmap, fun_arg([state], [state] | :drop), [key]) :: :ok
  def cast(agentmap, fun, keys) when is_fun(fun,1) and is_list(keys) do
    GenServer.cast pid(agentmap), %Req{action: :cast,
                                       data: {fun,keys}}
  end

  @spec cast(agentmap, key, fun_arg(state, state)) :: :ok
  def cast(agentmap, key, fun) when is_fun(fun,1) do
    GenServer.cast pid(agentmap), %Req{action: :cast,
                                       data: {key,fun}}
  end

  @spec cast(agentmap, :!, [{key, fun_arg( state, state)}]) :: :ok
  def cast(agentmap, :!, funs) do
    req = %Req{!: true, action: :cast, data: funs}
    batch agentmap, req
  end

  #2

  @doc """
  Version of `cast/4` to be used for batch processing. As in `cast/4`, urgent
  (`:!`) mark can be provided to make out of turn call. Works the same as
  `get/3`, `get_and_update/3` and `update/3`.
  """
  @spec cast(agentmap, [{key, fun_arg(state, state)}]) :: :ok
  def cast(agentmap, funs) do
    req = %Req{action: :cast, data: funs}
    batch agentmap, req
  end


  @doc """
  Sets the `:max_threads` value of the state with given `key`. Returns the old
  value.

  `agentmap` can execute `get` calls on the same key in parallel. `max_threads`
  option specifies number of threads per key used, minus one thread for the
  process holding the queue. By default five `get` calls on the same state could
  be executed, so

      iex> sleep100ms = fn _ ->
      ...>   :timer.sleep 100
      ...> end
      iex> mag = AgentMap.new key: 42
      iex> for _ <- 1..4, do: spawn fn ->
      ...>   AgentMap.get mag, :key, sleep100ms
      ...> end
      iex> AgentMap.get mag, :key, sleep100ms
      :ok

  will be executed in around of 100 ms, not 500. Be aware, that this call:

      iex> sleep100ms = fn _ ->
      ...>   :timer.sleep 100
      ...> end
      iex> mag = AgentMap.new key: 42
      iex> AgentMap.get mag, :key, sleep100ms
      iex> AgentMap.cast mag, :key, sleep100ms
      iex> AgentMap.cast mag, :key, sleep100ms
      :ok

  will be executed in around of 200 ms because `agentmap` can parallelize any
  sequence of `get/3` calls ending with `get_and_update/3`, `update/3` or
  `cast/3`.

  Use `max_threads: 1` to execute `get` calls in sequence.

  ## Examples

      iex> mag = AgentMap.new()
      iex> AgentMap.max_threads mag, :a, 42
      5
      iex> AgentMap.max_threads mag, :a, :infinity
      42
  """
  @spec max_threads(agentmap, key, pos_integer | :infinity) :: pos_integer | :infinity
  def max_threads(agentmap, key, value) do
    GenServer.call pid(agentmap), {:max_threads, key, value}
  end


  @doc """
  Fetches the value for a specific `key` in the given `agentmap`.

  If `agentmap` contains the given `key` with value value, then `{:ok, value}`
  is returned. If `map` doesn’t contain `key`, `:error` is returned.

  Examples

      iex> mag = AgentMap.new(a: 1)
      iex> AgentMap.fetch mag, :a
      {:ok, 1}
      iex> AgentMap.fetch mag, :b
      :error
  """
  @spec fetch(agentmap, key) :: {:ok, state} | :error
  def fetch(agentmap, key) do
    GenServer.call pid(agentmap), {:!, {:fetch, key}}
  end


  @doc """
  Returns whether the given `key` exists in the given `multimap`.

  ## Examples

      iex> mag = AgentMap.new( a: 1)
      iex> AgentMap.has_key?( mag, :a)
      true
      iex> AgentMap.has_key?( mag, :b)
      false
  """
  @spec has_key?(agentmap, key) :: boolean
  def has_key?(agentmap, key) do
    GenServer.call pid(agentmap), {:has_key?, key}
  end


  @doc """
  Returns and removes the value associated with `key` in `agentmap`. If `key`
  is present in `agentmap` with value `value`, `{value, agentmap}` is
  returned where `agentmap` is the same agentmap. State with given `key` is
  returned from `agentmap`. If `key` is not present in `agentmap`,
  `{default, agentmap}` is returned.

  Pair with agentmap is returned for compatibility with Access protocol, as it
  have `Access.pop/2` callback.

  ## Examples
      iex> mag = AgentMap.new a: 1
      iex> AgentMap.pop mag, :a
      1
      iex> AgentMap.pop mag, :a
      nil
      iex> AgentMap.pop mag, :b
      nil
      iex> Enum.empty? mag
      true
  """
  @spec pop(agentmap, key, any) :: state | any
  def pop(agentmap, key, default \\ nil) do
    GenServer.call pid(agentmap), %Req{action: :pop, data: {key, default}}
  end


  @doc """
  Puts the given `value` under `key` in `agentmap`.

  ## Examples
      iex> mag = AgentMap.new a: 1
      iex> AgentMap.put(mag, :b, 2) |>
      ...> AgentMap.take([:a, :b])
      %{a: 1, b: 2}
      iex> AgentMap.put(mag, :a, 3) |>
      ...> AgentMap.take([:a, :b])
      %{a: 3, b: 2}
  """
  @spec put(agentmap, key, state) :: agentmap
  def put(agentmap, key, state) do
    GenServer.cast pid(agentmap), %Req{action: :put, data: {key, state}}
    agentmap
  end

  @spec put(agentmap, :!, key, state) :: agentmap
  def put(agentmap, :!, key, state) do
    GenServer.cast pid(agentmap), %Req{!: true, action: :put, data: {key, state}}
    agentmap
  end

  @doc """
  Fetches the value for a specific `key` in the given `agentmap`, erroring out
  if `agentmap` doesn't contain `key`. If `agentmap` contains the given
  `key`, the corresponding value is returned. If `agentmap` doesn't contain
  `key`, a `KeyError` exception is raised.

  ## Examples

      iex> mag = AgentMap.new a: 1
      iex> AgentMap.fetch! mag, :a
      1
      iex> AgentMap.fetch! mag, :b
      ** (KeyError) key :b not found
  """
  @spec fetch!(agentmap, key) :: state | no_return
  def fetch!(agentmap, key) do
    case GenServer.call pid(agentmap), {:!, {:fetch, key}} do
      {:ok, state} -> state
      :error -> raise KeyError, key: key
    end
  end


  @doc """
  Returns a `Map` with all the key-value pairs in `agentmap` where the key is
  in `keys`. If `keys` contains keys that are not in `multimap`, they're simply
  ignored.

  ## Examples
      iex> AgentMap.new( a: 1, b: 2, c: 3) |>
      ...> AgentMap.take([:a, :c, :e])
      %{a: 1, c: 3}
  """
  @spec take(agentmap, Enumerable.t()) :: map
  def take(agentmap, keys) do
    GenServer.call pid(agentmap), {:!, {:take, keys}}
  end


  @doc """
  Deletes the entry in `agentmap` for a specific `key`. If the `key` does not
  exist, returns `agentmap` unchanged.

  Syntax sugar to `get_and_update agentmap, :!, key, fn _ -> :pop end`.

  ## Examples

      iex> mag = AgentMap.new a: 1, b: 2
      iex> AgentMap.delete mag, :a
      iex> AgentMap.take mag, [:a, :b]
      %{b: 2}
      #
      iex> AgentMap.delete mag, :a
      iex> AgentMap.take mag, [:a, :b]
      %{b: 2}
  """
  @spec delete(agentmap, key) :: agentmap
  def delete(agentmap, key) do
    get_and_update agentmap, :!, key, fn _ -> :pop end
    agentmap
  end


  @doc """
  Drops the given `keys` from `agentmap`. If `keys` contains keys that are not
  in `agentmap`, they're simply ignored.

  Syntax sugar to transaction call

      get_and_update agentmap, :!, fn _ -> :pop end, keys

  ## Examples

      iex> AgentMap.new(a: 1, b: 2, c: 3) |>
      ...> AgentMap.drop([:b, :d]) |>
      ...> AgentMap.keys()
      [:a, :c]
  """
  @spec drop(agentmap, Enumerable.t()) :: agentmap
  def drop(agentmap, keys) do
    get_and_update agentmap, :!, fn _ -> :pop end, keys
    agentmap
  end


  @doc """
  Keys of all the `agentmap` states.

  ## Examples

  iex> AgentMap.new(a: 1, b: 2, c: 3) |>
  ...> AgentMap.keys()
  [:a, :b, :c]
  """
  @spec keys(agentmap) :: [key]
  def keys(agentmap) do
    GenServer.call pid(agentmap), :keys
  end


  @doc """
  Length of the queue for `key`.

  ## Examples

  iex> mag = AgentMap.new a: 1, b: 2
  iex> AgentMap.queue_len mag, :a
  0
  iex> AgentMap.update mag, :a, fn _ -> :timer.sleep(100) end
  iex> AgentMap.update mag, :a, fn _ -> :timer.sleep(100) end
  iex> AgentMap.queue_len mag, :a
  1
  iex> AgentMap.queue_len mag, :b
  0
  """
  @spec queue_len(agentmap, key) :: non_neg_integer
  def queue_len(agentmap, key) do
    GenServer.call pid(agentmap), {:queue_len, key}
  end


  @doc """
  Synchronously stops the agentmap with the given `reason`.

  It returns `:ok` if the agentmap terminates with the given reason. If the
  agentmap terminates with another reason, the call will exit.

  This function keeps OTP semantics regarding error reporting. If the reason is
  any other than `:normal`, `:shutdown` or `{:shutdown, _}`, an error report
  will be logged.

  ## Examples

  iex> {:ok, pid} = AgentMap.start_link()
  iex> AgentMap.stop pid
  :ok
  """
  @spec stop(agentmap, reason :: term, timeout) :: :ok
  def stop(agentmap, reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop pid(agentmap), reason, timeout
  end
end

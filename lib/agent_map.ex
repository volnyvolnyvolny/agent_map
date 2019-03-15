defmodule AgentMap do
  require Logger

  @enforce_keys [:pid]
  defstruct @enforce_keys

  alias AgentMap.{Req, Multi}

  @moduledoc """
  `AgentMap` can be seen as a stateful `Map` that parallelize operations made on
  different keys. Basically, it can be used as a cache, memoization,
  computational framework and, sometimes, and as an alternative to `GenServer`.
  `AgentMap` supports operations made on a group of keys (["multi-key"
  calls](AgentMap.Multi.html)).

  ## Examples

  Create and use it as an ordinary `Map` (`new/0`, `new/1` and `new/2`):

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> AgentMap.get(am, :a)
      42
      iex> AgentMap.keys(am)
      [:a, :b]
      iex> am
      ...> |> AgentMap.update(:a, & &1 + 1)
      ...> |> AgentMap.update(:b, & &1 - 1)
      ...> |> AgentMap.to_map()
      %{a: 43, b: 23}
      #
      iex> Enum.count(am)
      2

  or in an `Agent` manner (`start/2`, `start_link/2`):

      iex> {:ok, pid} = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.put(:a, 1)
      ...> |> AgentMap.get(:a)
      1

  Struct `%AgentMap{}` allows to use `Enumerable` and `Collectable` protocols:

      iex> {:ok, pid} = AgentMap.start_link()
      iex> am = AgentMap.new(pid)
      ...> Enum.empty?(am)
      true
      #
      iex> Enum.into([a: 1, b: 2], am)
      iex> AgentMap.to_map(am)
      %{a: 1, b: 2}

  See [README](readme.html#examples) for memoization and accounting examples.

  ## Priority (`:!`)

  Most of the functions support `!: priority` option to make out-of-turn
  ("priority") calls.

  Priority can be given as a non-negative integer or alias. Aliases are: `:min |
  :low` = `0`, `:avg | :mid` = `255`, `:max | :high` = `65535`. Relative value
  are also acceptable, for ex.: `{:max, -1}` = `65534`.

      iex> AgentMap.new(state: :ready)
      ...> |> sleep(:state, 10)                                       # 0 — creates a worker
      ...> |> cast(:state, fn :go!    -> :stop   end)                 # :   ↱ 3
      ...> |> cast(:state, fn :steady -> :go!    end, !: :max)        # : ↱ 2 :
      ...> |> cast(:state, fn :ready  -> :steady end, !: {:max, +1})  # ↳ 1   :
      ...> |> get(:state)                                             #       ↳ 4
      :stop

  Also, `!: :now` option can be given in `get/4`, `get_lazy/4` or `take/3` to
  instruct `AgentMap` to make execution using a separate `Task` and *current*
  values. Calls `fetch!/3`, `fetch/3`, `values/2`, `to_map/2` and `has_key?/3`
  use this option by default:

      iex> am =
      ...>   AgentMap.new(key: 1)
      iex> am
      ...> |> sleep(:key, 20)                 # 0        — creates a sleepy worker
      ...> |> put(:key, 42)                   # ↳ 1 ┐
      ...>                                    #     :
      ...> |> fetch(:key)                     # 0   :
      {:ok, 1}                                #     :
      iex> get(am, :key, & &1 * 99, !: :now)  # 0   :
      99                                      #     :
      iex> get(am, :key, & &1 * 99)           #     ↳ 2
      4158

  ## How it works

  Underneath it's a `GenServer` that holds a `Map`. When a state changing call
  (`update/4`, `get_and_update/4`, …) is first made for a key, a special
  temporary worker-process is spawned. All subsequent calls are forwarded to the
  message queue of this worker, which respects the order of incoming new calls.
  Worker executes them in a sequence, except for `get/4` calls, which are
  processed as a parallel `Task`s. A worker will die after `~20` ms of
  inactivity.

  For example:

      iex> am = AgentMap.new(a: 1)
      iex> am
      ...> |> cast(:a, & &1 + 1)              # new worker is spawned for `:a` and …
      ...>                                    # callback `& &1 + 1` is added to its queue
      ...> |> get(:a)                         # callback `& &1` is added to the same queue
      2                                       # now all callbacks are invoked
      iex> sleep(40)                          # worker is inactive for > 20 ms…
      ...>                                    # …so it dies
      iex> get(am, :a, & &1 + 1)              # `& &1 + 1` is executed in a Task process…
      ...>                                    # …no worker is spawned
      3

  or:

      iex> am = AgentMap.new(a: 1)            # server    worker   queue
      iex> am                                 # %{a: 1}   —        —
      ...> |> cast(:a, & &1 + 1)              # %{}       1        [& &1 + 1]
      ...> |> get(:a)                         # %{}       1        [& &1 + 1, get]
      2                                       # %{}       2        []
                                              #
      iex> sleep(40)                          # …worker dies
      iex> get(am, :a, & &1 + 1)              # %{a: 2}   —        —
      3

  Sometimes, like in the above example, it's more expensive to spawn a new
  worker and handle logic related to its death than to execute callback on
  server. For this particular case `tiny: true` option can be provided to
  `get_and_update/4`, `update/4`, `update!/4`, `put_new_lazy/4` and `cast/4`
  calls. When it's given, callback is invoked inside `GenServer`'s loop and no
  additional workers are spawned:

      iex> am = AgentMap.new(a: 1)
      iex> am
      ...> |> cast(:a, & &1 + 1, tiny: true)  # callback `& &1 + 1` is executed by server
      ...> |> get(:a)                         # server returns the current value
      2                                       #
      iex> get(am, :a, & &1 + 1)              # `& &1 + 1` is executed in a Task process
      3

  Be aware, that when invoking callbacks, server could not handle any other
  requests. For example, this:

      iex> am = AgentMap.new(a: 42)           # {:ok, pid} = Agent.start(fn -> %{a: 42} end)
      iex> am                                 # pid
      ...> |> cast(:b, fn _ ->                # |> Agent.cast(fn _ ->
      ...>      sleep(50)                     #      sleep(50)
      ...>      24                            #      %{a: 42, b: 24}
      ...>    end, tiny: true)                #    end)
      ...> |> get(:a)                         #
      42                                      #
      iex> get(am, :b)                        # Agent.get(pid, & &1)
      24                                      # %{a: 42, b: 24}

  will be handled in around of `50` ms. In this case `AgentMap` behaves exactly
  like `Agent` with a map given as a state.

  ## Other

  `AgentMap` is bound to the same name registration rules as `GenServers`, see
  `GenServer` documentation for details.

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

  See `Supervisor` docs.
  """

  @max_p 5000

  @typedoc "Return values for `start` and `start_link` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid} | [{key, reason}]}

  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "`AgentMap` instance"
  @type am :: pid | {atom, node} | name | %AgentMap{}

  @type key :: term
  @type value :: term
  @type initial :: value
  @type default :: initial
  @type reason :: term
  @type alias :: :low | :mix | :mid | :avg | :high | :max
  @type delta :: integer
  @type priority :: alias | {alias, delta} | :now | non_neg_integer

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

  #

  @doc false
  defguard is_timeout(t)
           when (is_integer(t) and t > 0) or t == :infinity

  #

  @doc false
  def _call(%_{pid: _} = am, req, opts) do
    _call(am.pid, req, opts)
  end

  def _call(am, req, opts) do
    opts =
      Keyword.put_new(opts, :initial, opts[:default])

    req = struct(req, opts)
    pid = (is_map(am) && am.pid) || am

    if opts[:cast] do
      GenServer.cast(pid, req)
      am
    else
      GenServer.call(pid, req, opts[:timeout] || 5000)
    end
  end

  @doc false
  def _call(am, req, opts, defs) do
    _call(am, req, Keyword.merge(defs, opts))
  end

  #

  defp prep!(max_p) when is_timeout(max_p) do
    {max_p, :infinity}
  end

  defp prep!({soft, hard}) when hard < soft do
    #
    raise ArgumentError, """
    Hard limit must be greater than soft.
    Got contrary: #{inspect({soft, hard})}
    """
  end

  defp prep!({_soft, _h} = max_p) do
    max_p
  end

  defp prep!(malformed) do
    raise ArgumentError, """
    Value for option :max_processes is malformed.
    Got: #{inspect(malformed)}
    """
  end


  ##
  ## NEW
  ##

  @doc """
  Returns a new instance of `AgentMap`.

  ## Examples

      iex> AgentMap.new()
      ...> |> Enum.empty?()
      true
  """
  @spec new :: am
  def new, do: new(%{})

  @doc """
  Starts an `AgentMap` via `start_link/1` function.

  As an argument, enumerable with keys and values may be provided or the PID of
  an already started `AgentMap`.

  Returns a new instance of `AgentMap` wrapped in a `%AgentMap{}`. This struct
  allows to use `Enumerable` and `Collectable` protocols.

  ## Examples

      iex> am = AgentMap.new(a: 42, b: 24)
      iex> get(am, :a)
      42
      iex> keys(am)
      [:a, :b]

      iex> {:ok, pid}
      ...>   = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.new()
      ...> |> put(:a, 1)
      ...> |> get(:a)
      1

      iex> {:ok, pid}
      ...>   = AgentMap.start_link()
      iex> pid
      ...> |> AgentMap.new()
      ...> |> Enum.empty?()
      true

      iex> {:ok, pid}
      ...>   = AgentMap.start_link()
      ...>
      iex> %{a: 2, b: 3}
      ...> |> Enum.into(AgentMap.new(pid))
      ...> |> to_map()
      %{a: 2, b: 3}
  """
  @spec new(Enumerable.t() | am) :: am
  def new(enumerable)

  def new(%__MODULE__{} = am) do
    raise "AgentMap is already started. PID: #{inspect(am.pid)}"
  end

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
  Creates an `AgentMap` instance from `enumerable` via the given transformation
  function.

  Duplicated keys are removed; the latest one prevails.

  ## Examples

      iex> [:a, :b]
      ...> |> AgentMap.new(&{&1, to_string(&1)})
      ...> |> to_map()
      %{a: "a", b: "b"}
  """
  @spec new(Enumerable.t(), (term -> {key, value})) :: am
  def new(enumerable, transform) do
    new(Map.new(enumerable, transform))
  end


  ##
  ## START / START_LINK
  ##

  @doc """
  Starts a linked `AgentMap` instance.

  Argument `funs` is a keyword that contains pairs `{key, fun/0}`. Each `fun` is
  executed in a separate `Task` and return an initial value for `key`.

  ## Options

    * `name: term` — is used for registration as described in the module
      documentation;

    * `:debug` — is used to invoke the corresponding function in [`:sys`
      module](http://www.erlang.org/doc/man/sys.html);

    * `:spawn_opt` — is passed as options to the underlying process as in
      `Process.spawn/4`;

    * `:timeout`, `5000` — `AgentMap` is allowed to spend at most
      the given number of milliseconds on the whole process of initialization or
      it will be terminated;

    * `max_processes: pos_integer | :infinity | {pos_integer, pos_integer}`,
      `#{@max_p}` — a maximum number of processes instance can have. Limit can
      be "soft" — if it is exceeded, optimizations are applied; or "hard" — if
      it's exceeded and no optimization can be made to spawn workers, all
      requests are handled in a server process, one by one. For example,
      `max_processes: 100` ≅ `max_processes: {100, :infinity}` mean `99`
      processes can be spawned before optimizations are made, and no
      hard-limitation is given.

  ## Return values

  If an instance is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a server with the
  specified name already exists, the function returns `{:error,
  {:already_started, pid}}` with the PID of that process.

  If one of the callbacks fails, the function returns `{:error, [{key,
  reason}]}`, where `reason` is `:timeout`, `:badfun`, `:badarity`, `{:exit,
  reason}` or an arbitrary exception.

  ## Examples

  To start server with a single key `:k`.

      iex> {:ok, pid} =
      ...>   AgentMap.start_link(k: fn -> 42 end)
      iex> get(pid, :k)
      42
      iex> get_prop(pid, :max_processes)
      {#{@max_p}, :infinity}

  The following will not work:

      iex> AgentMap.start(k: 3)
      {:error, k: :badfun}
      #
      iex> AgentMap.start(k: & &1)
      {:error, k: :badarity}
      #
      iex> {:error, k: {e, _st}} =
      ...>   AgentMap.start(k: fn -> raise "oops" end)
      iex> e
      %RuntimeError{message: "oops"}

  To start server without any keys use:

      iex> AgentMap.start([], name: Account)
      iex> Account
      ...> |> put(:a, 42)
      ...> |> get(:a)
      42
  """
  @spec start_link([{key, (() -> any)}], GenServer.options()) :: on_start
  def start_link(funs \\ [], opts \\ [max_processes: @max_p]) do
    start(funs, [{:link, true} | opts])
  end

  @doc """
  Starts an unlinked `AgentMap` instance.

  See `start_link/2` for details.

  ## Examples

      iex> err =
      ...>   AgentMap.start([a: 42,
      ...>                   b: fn -> sleep(:infinity) end,
      ...>                   c: fn -> raise "oops" end,
      ...>                   d: fn -> :ok end],
      ...>                   timeout: 10)
      ...>
      iex> {:error, a: :badfun, b: :timeout, c: {e, _st}} = err
      iex> e
      %RuntimeError{message: "oops"}
  """
  @spec start([{key, (() -> any)}], GenServer.options()) :: on_start
  def start(funs \\ [], opts \\ [max_processes: @max_p]) do
    args =
      [
        funs: funs,
        timeout: opts[:timeout] || 5000,
        max_p: prep!(opts[:max_processes] || @max_p)
      ]

    # Global timeout must be turned off.
    opts =
      opts
      |> Keyword.put(:timeout, :infinity)
      |> Keyword.delete(:max_processes)
      |> Keyword.delete(:link)

    if opts[:link] do
      GenServer.start_link(AgentMap.Server, args, opts)
    else
      GenServer.start(AgentMap.Server, args, opts)
    end
  end


  ##
  ## STOP
  ##

  @doc """
  Synchronously stops the `AgentMap` instance with the given `reason`.

  Returns `:ok` if terminated with the given reason. If it terminates with
  another reason, the call will exit.

  This function keeps OTP semantics regarding error reporting. If the reason is
  any other than `:normal`, `:shutdown` or `{:shutdown, _}`, an error report
  will be logged.

  ### Examples

      iex> {:ok, pid} = AgentMap.start_link()
      iex> AgentMap.stop(pid)
      :ok
  """
  @spec stop(am, reason :: term, timeout) :: :ok
  def stop(am, reason \\ :normal, timeout \\ :infinity)

  def stop(%__MODULE__{} = am, reason, timeout) do
    GenServer.stop(am.pid, reason, timeout)
  end

  def stop(pid, reason, timeout) do
    GenServer.stop(pid, reason, timeout)
  end


  ##
  ## GET / GET_LAZY / FETCH / FETCH!
  ##

  @doc """
  Gets a value via the given `fun`.

  A callback `fun` is sent to an instance that invokes it, passing as an
  argument the value associated with `key`. The result of an invocation is
  returned from this function. This call does not change value, and so, workers
  execute a series of `get`-calls as a parallel `Task`s.

  ## Options

    * `:default`, `nil` — value for `key` if it's missing;

    * `!: priority`, `:avg`;

    * `!: :now` — to execute call in a separate `Task` (passing current value),
      spawned from server:

          iex> am = AgentMap.new()
          iex> sleep(am, :key, 40)
          iex> for _ <- 1..100 do
          ...>   Task.async(fn ->
          ...>     get(am, :key, fn _ -> sleep(40) end, !: :now)
          ...>   end)
          ...> end
          iex> sleep(10)
          iex> get_prop(am, :processes)
          102

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new()
      iex> get(am, :Alice, & &1)
      nil
      iex> am
      ...> |> put(:Alice, 42)
      ...> |> get(:Alice, & &1 + 1)
      43
      iex> get(am, :Bob, & &1 + 1, default: 0)
      1
  """
  @spec get(am, key, (value | default -> get), keyword | timeout) :: get
        when get: var
  def get(am, key, fun, opts)

  def get(am, key, fun, t) when is_timeout(t) do
    get(am, key, fun, timeout: t)
  end

  def get(am, k, f, opts) do
    req = %Req{act: :get, key: k, fun: f}
    _call(am, req, opts, !: :avg)
  end

  @doc """
  Returns the value for a specific `key`.

  This call has the `:min` priority. As so, the value is retrived only after all
  other calls for `key` are completed.

  See `get/4`, `AgentMap.Multi.get/3`.

  ## Options

    * `:default`, `nil` — value to return if `key` is missing;

    * `!: priority`, `:min`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(Alice: 42)
      iex> get(am, :Alice)
      42
      iex> get(am, :Bob)
      nil

  By default, `get/4` has the `:min` priority:

      iex> AgentMap.new(a: 42)
      ...> |> sleep(:a, 20)           # 0      — creates a worker
      ...> |> put(:a, 0)              # : ↱ 2  — !: :max
      ...> |> get(:a, !: {:max, +1})  # ↳ 1
      42
  """
  @spec get(am, key, keyword) :: value | default
  def get(am, key, opts \\ [!: :min])

  def get(am, key, opts) when is_list(opts) do
    opts =
      opts
      |> Keyword.put_new(:!, :min)
      |> Keyword.put(:tiny, true)

    get(am, key, & &1, opts)
  end

  def get(am, key, fun) do
    get(am, key, fun, [])
  end

  # @doc """
  # Gets the value for a specific `key`.

  # If `key` is present, return its value. Otherwise, `fun` is evaluated and the
  # result is returned.

  # This is useful if the default value is very expensive to calculate or
  # generally difficult to setup and teardown again.

  # See `get/4`.

  # ## Options

  #   * `!: :now` — to execute this call in a separate `Task` (passing a current
  #     value) spawned from server;

  #   * `!: priority`, `:avg`;

  #   * `:timeout`, `5000`.

  # ## Examples

  #     iex> am = AgentMap.new(a: 1)
  #     iex> fun = fn ->
  #     ...>   # some expensive operation here
  #     ...>   13
  #     ...> end
  #     iex> get_lazy(am, :a, fun)
  #     1
  #     iex> get_lazy(am, :b, fun)
  #     13
  # """
  # @spec get_lazy(am, key, (() -> a), keyword | timeout) :: value | a
  #       when a: var
  # #
  # def get_lazy(am, key, fun, opts \\ [!: :avg])

  # def get_lazy(am, key, fun, t) when is_timeout(t) do
  #   get_lazy(am, key, fun, timeout: t)
  # end

  # def get_lazy(am, key, fun, opts) do
  #   fun = fn value, exist? ->
  #     (exist? && value) || fun.()
  #   end

  #   get(am, key, fun, opts)
  # end

  @doc """
  Fetches the current value for a specific `key`.

  Returns `{:ok, value}` or `:error` if `key` is not present.

  ## Options

    * `!: priority`, `:now` — to return only when calls with higher
      [priorities](#module-priority) are finished for this `key`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> fetch(am, :a)
      {:ok, 1}
      iex> fetch(am, :b)
      :error

  By default, this call returns the current `key` value. As so, any pending
  operations will have no effect:

      iex> am = AgentMap.new()
      iex> am
      ...> |> sleep(:a, 20)        # 0        — creates a worker for this key
      ...> |> put(:a, 42)          # ↳ 1 ┐    — …pending
      ...>                         #     :
      ...> |> fetch(:a)            # 0   :
      :error                       #     :
      #                                  :
      iex> fetch(am, :a, !: :avg)  #     ↳ 2
      {:ok, 42}
  """
  @spec fetch(am, key, keyword | timeout) :: {:ok, value} | :error
  def fetch(am, key, opts \\ [!: :now])

  def fetch(am, key, t) when is_timeout(t) do
    fetch(am, key, timeout: t)
  end

  def fetch(am, key, opts) do
    get(
      am,
      key,
      fn value, exist ->
        (exist && {:ok, value}) || :error
      end,
      [{:tiny, true} | opts]
    )
  end

  @doc """
  Fetches the value for a specific `key`, erroring out if instance doesn't
  contain `key` at the moment.

  Returns current value or raises a `KeyError`.

  See `fetch/3`.

  ## Options

    * `!: priority`, `:now` — to return only when calls with higher
      [priorities](#module-priority) are finished for this `key`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> fetch!(am, :a)
      1
      iex> fetch!(am, :b)
      ** (KeyError) key :b not found
  """
  @spec fetch!(am, key, keyword | timeout) :: value | no_return
  def fetch!(am, key, opts \\ [!: :now]) do
    case fetch(am, key, opts) do
      {:ok, value} ->
        value

      :error ->
        raise KeyError, key: key
    end
  end


  ##
  ## GET_AND_UPDATE
  ##

  @doc """
  Gets the value for `key` and updates it, all in one pass.

  The `fun` is sent to an `AgentMap` that invokes it, passing the value for
  `key`. A callback can return:

    * `{ret, new value}` — to set new value and retrive "ret";
    * `{ret}` — to retrive "ret" value;
    * `:pop` — to retrive current value and remove `key`;
    * `:id` — to just retrive current value.

  For example, `get_and_update(account, :Alice, &{&1, &1 + 1_000_000})` returns
  the balance of `:Alice` and makes the deposit, while `get_and_update(account,
  :Alice, &{&1})` just returns the balance.

  This call creates a temporary worker that is responsible for holding queue of
  calls awaiting execution for `key`. If such a worker exists, call is added to
  the end of its queue. Priority can be given (`:!`), to process call out of
  turn.

  See `Map.get_and_update/3`.

  ## Options

    * `:initial`, `nil` — value for `key` if it's missing;

    * `tiny: true` — to execute `fun` on [server](#module-how-it-works) if it's
      possible;

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 42)
      ...>
      iex> get_and_update(am, :a, &{&1, &1 + 1})
      42
      iex> get(am, :a)
      43
      iex> get_and_update(am, :a, fn _ -> :pop end)
      43
      iex> has_key?(am, :a)
      false
      iex> get_and_update(am, :a, fn _ -> :id end)
      nil
      iex> has_key?(am, :a)
      false
      iex> get_and_update(am, :a, &{&1, &1})
      nil
      iex> has_key?(am, :a)
      true
      iex> get_and_update(am, :b, &{&1, &1}, initial: 42)
      42
      iex> has_key?(am, :b)
      true
  """
  @spec get_and_update(
          am,
          key,
          (value | initial -> {ret} | {ret, value} | :pop | :id),
          keyword | timeout
        ) :: ret | value | initial
        when ret: var
  def get_and_update(am, key, fun, opts \\ [!: :avg])

  def get_and_update(am, key, fun, t) when is_timeout(t) do
    get_and_update(am, key, fun, timeout: t)
  end

  def get_and_update(am, k, f, opts) do
    req = %Req{act: :upd, key: k, fun: f}

    if opts[:!] == :now do
      raise ArgumentError, """
      `:now` priority cannot be used in a `get_and_update/4` call!
      """
    end

    _call(am, req, opts, !: :avg)
  end


  ##
  ## UPDATE / UPDATE! / REPLACE!
  ##

  @doc """
  Updates `key` with the given `fun`.

  See `get_and_update/4`.

  ## Options

    * `:initial`, `nil` — value for `key` if it's missing;

    * `tiny: true` — to execute `fun` on [server](#module-how-it-works) if it's
      possible;

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> AgentMap.new(Alice: 24)
      ...> |> update(:Alice, & &1 + 1_000)
      ...> |> get(:Alice)
      1024

      iex> AgentMap.new()
      ...> |> update(:a, fn nil -> 42 end)
      ...> |> get(:a)
      42

      iex> AgentMap.new()
      ...> |> update(:a, & &1 + 18, initial: 24)
      ...> |> get(:a)
      42
  """
  @spec update(am, key, (value | initial -> value), keyword | timeout) :: am
  def update(am, key, fun, opts \\ [!: :avg]) do
    get_and_update(am, key, &{am, fun.(&1)}, opts)
  end

  @doc """
  Updates known `key` with the given function.

  If `key` is present, `fun` is invoked with value as argument and its result is
  used as the new value. Otherwise, a `KeyError` exception is raised.

  See `update/4`.

  ## Options

    * `!: priority`, `:avg`;

    * `tiny: true` — to execute `fun` on [server](#module-how-it-works) if it's
      possible;

    * `:timeout`, `5000`.

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)                              # 0a
      ...> |> put(:a, 3)                                 # : ↱ 2a ┐
      ...> |> update!(:a, fn 1 -> 2 end, !: {:max, +1})  # ↳ 1a   ↓
      ...> |> update!(:a, fn 3 -> 4 end)                 #        3a
      ...> |> update!(:b, & &1)                          # 0b
      ** (KeyError) key :b not found
  """
  @spec update!(am, key, (value -> value), keyword | timeout) :: am | no_return
  def update!(am, key, fun, opts \\ [!: :avg]) do
    fun = fn value, exist? ->
      (exist? && {:ok, fun.(value)}) || {:error}
    end

    case get_and_update(am, key, fun, opts) do
      :error ->
        raise KeyError, key: key

      :ok ->
        am
    end
  end

  @doc """
  Alters the value stored under `key`, but only if `key` already exists.

  If `key` is not present, a `KeyError` exception is raised.

  See `update!/4`.

  ## Options

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1, b: 2)
      iex> am
      ...> |> replace!(:a, 3)
      ...> |> values()
      [3, 2]
      iex> replace!(am, :c, 2)
      ** (KeyError) key :c not found
  """
  @spec replace!(am, key, value, keyword | timeout) :: am
  def replace!(am, key, value, opts \\ [!: :avg])

  def replace!(am, key, value, t) when is_timeout(t) do
    replace!(am, key, value, timeout: t)
  end

  def replace!(am, key, v, opts) do
    update!(am, key, fn _ -> v end, [{:tiny, true} | opts])
  end


  ##
  ## HAS_KEY? / KEYS / VALUES
  ##

  @doc """
  Returns whether the given `key` exists at the moment.

  See `fetch/3`.

  ## Options

    * `!: priority`, `:now`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(a: 1)
      iex> has_key?(am, :a)
      true
      iex> has_key?(am, :b)
      false
      iex> am
      ...> |> delete(:a)
      ...> |> has_key?(:a)
      false

  By default, this call returns a `key` value at the moment. As so, any pending
  operations will have no effect:

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)          # — creates a worker for this key
      ...> |> delete(:a)             # — …pending
      ...> |> has_key?(:a)
      true

  use `:!` option to bypass:

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)          # 0
      ...> |> delete(:a)             # ↳ 1
      ...> |> has_key?(:a, !: :min)  #   ↳ 2
      false
  """
  @spec has_key?(am, key, keyword | timeout) :: boolean
  def has_key?(am, key, opts \\ [!: :now]) do
    match?({:ok, _}, fetch(am, key, opts))
  end

  @doc """
  Returns all keys.

  ## Examples

      iex> %{a: 1, b: nil, c: 3}
      ...> |> AgentMap.new()
      ...> |> keys()
      [:a, :b, :c]
  """
  @spec keys(am) :: [key]
  def keys(am) do
    _call(am, %Req{act: :keys}, timeout: 5000)
  end

  @doc """
  Returns current values stored by `AgentMap` instance.

  ## Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> values()
      [1, 2, 3]

  This call returns values as they are at the moment, so any pending
  operations will have no effect:

      iex> AgentMap.new(a: 1, b: 2, c: 3)
      ...> |> sleep(:a, 20)
      ...> |> put(:a, 0)                   # pending
      ...> |> values()
      [1, 2, 3]
  """
  @spec values(am) :: [value]
  def values(am) do
    _call(am, %Req{act: :values}, timeout: 5000)
  end


  ##
  ## PUT / PUT_NEW / PUT_NEW_LAZY
  ##

  @doc """
  Puts the given `value` under `key`.

  Returns without waiting for the actual put.

  Default [priority](#module-priority) for this call is `:max`.

  ## Options

    * `cast: false` — to return after the actual put;

    * `!: priority`, `:max`;

    * `:timeout`, `5000`.

  ## Examples

      iex> AgentMap.new()
      ...> |> put(:a, 42)
      ...> |> put(:b, 42)
      ...> |> to_map()
      %{a: 42, b: 42}

  By default, `put/4` has the `:max` priority:

      iex> AgentMap.new(a: 42)     #                 server    worker  queue
      ...> |> sleep(:a, 20)        #                 %{a: 42}  —       —
      ...>                         #
      ...> |> put(:a, 1, !: :min)  #     ↱ 3a ┐      %{}       42      [min]
      ...> |> put(:a, 2, !: :avg)  #  ↱ 2a    :      %{}       42      [avg, min]
      ...> |> put(:a, 3)           # 1a       :      %{}       42      [max, avg, min]
      ...> |> get(:a)              #          ↳ 4a   %{}       42      [max, avg, min, get]
      1                            #                 %{}       1       []
                                   #
                                   #                 the worker dies after ~20 ms:
                                   #                 %{a: 1}   —       —

  but:

      iex> AgentMap.new()          #                 %{}       —       —
      ...> |> put(:a, 1, !: :min)  # 1               %{a: 1}   —       —
      ...> |> put(:a, 2, !: :avg)  # ↳ 2             %{a: 2}   —       —
      ...> |> put(:a, 3)           #   ↳ 3           %{a: 3}   —       —
      ...> |> get(:a)              #     ↳ 4         %{a: 3}   —       —
      3
  """
  @spec put(am, key, value, keyword) :: am
  def put(am, key, value, opts \\ [cast: true, !: :max]) do
    opts =
      opts
      |> Keyword.put_new(:!, :max)
      |> Keyword.put_new(:cast, true)
      |> Keyword.put_new(:tiny, true)

    update(am, key, fn _ -> value end, opts)
  end

  @doc """
  Puts the given `value` under `key`, unless the entry already exists.

  Returns without waiting for the actual put.

  Default [priority](#module-priority) for this call is `:max`.

  See `put/4`.

  ## Options

    * `cast: false` — to return after the actual put;

    * `!: priority`, `:max`;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> put_new(:a, 42)
      ...> |> put_new(:b, 42)
      ...> |> to_map()
      %{a: 1, b: 42}
  """
  @spec put_new(am, key, value, keyword) :: am
  def put_new(am, key, value, opts \\ [cast: true, !: :max]) do
    put_new_lazy(am, key, fn -> value end, [{:tiny, true} | opts])
  end

  @doc """
  Evaluates `fun` and puts the result under `key`, unless it is already present.

  Returns without waiting for the actual put.

  This function is useful in case you want to compute the value to put under
  `key` only if it is not already present (e.g., the value is expensive to
  calculate or generally difficult to setup and teardown again).

  Default [priority](#module-priority) for this call is `:max`.

  See `put_new/4`.

  ## Options

    * `cast: false` — to return after the actual put;

    * `!: priority`, `:max`;

    * `tiny: true` — to execute `fun` on [server](#module-how-it-works) if it's
      possible;

    * `:timeout`, `5000`.

  ## Examples

      iex> fun = fn ->
      ...>   # some expensive operation
      ...>   42
      ...> end
      ...>
      iex> %{a: 1}
      ...> |> AgentMap.new()
      ...> |> put_new_lazy(:a, fun, cast: false)
      ...> |> put_new_lazy(:b, fun, cast: false)
      ...> |> to_map()
      %{a: 1, b: 42}
  """
  @spec put_new_lazy(am, key, (() -> value), keyword) :: am
  def put_new_lazy(am, key, fun, opts \\ [cast: true, !: :max]) do
    opts =
      opts
      |> Keyword.put_new(:!, :max)
      |> Keyword.put_new(:cast, true)

    fun = fn _, exist? ->
      (exist? && :id) || {:_ret, fun.()}
    end

    get_and_update(am, key, fun, opts)
    am
  end


  ##
  ## POP / DELETE / DROP
  ##

  @doc """
  Removes and returns the value associated with `key`.

  If there is no such `key`, `default` is returned (`nil`).

  ## Options

    * `!: priority`, `:avg`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am =
      ...>   AgentMap.new(a: 42, b: nil)
      ...>
      iex> pop(am, :a)
      42
      iex> pop(am, :a)
      nil
      iex> pop(am, :a, :error)
      :error
      iex> pop(am, :b, :error)
      nil
      iex> pop(am, :b, :error)
      :error
      iex> Enum.empty?(am)
      true
  """
  @spec pop(am, key, default, keyword | timeout) :: value | default
  def pop(am, key, default \\ nil, opts \\ [!: :avg])

  def pop(am, key, default, t) when is_timeout(t) do
    pop(am, key, default, timeout: t)
  end

  def pop(am, key, default, opts) do
    opts =
      opts
      |> Keyword.put_new(:!, :avg)
      |> Keyword.put(:tiny, true)
      |> Keyword.put(:initial, default)

    fun = fn _ -> :pop end
    get_and_update(am, key, fun, opts)
  end

  @doc """
  Deletes entry for `key`.

  Returns without waiting for the actual delete to occur.

  Default [priority](#module-priority) for this call is `:max`.

  ## Options

    * `cast: false` — to return only after the actual removal;

    * `!: priority`, `:max`;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1, b: 2}
      ...> |> AgentMap.new()
      ...> |> delete(:a)
      ...> |> to_map()
      %{b: 2}
  """
  @spec delete(am, key, keyword) :: am
  def delete(am, key, opts \\ [cast: true, !: :max]) do
    opts =
      opts
      |> Keyword.put_new(:!, :max)
      |> Keyword.put_new(:cast, true)
      |> Keyword.put(:tiny, true)

    get_and_update(am, key, fn _ -> :pop end, opts)

    am
  end

  @doc """
  Drops given `keys`.

  Returns without waiting for the actual drop to occur.

  This call has a fixed priority `{:avg, +1}`.

  ## Options

    * `cast: false` — to return only after delete is finished for all
      `keys`;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> drop([:b, :d], cast: false)
      ...> |> to_map()
      %{a: 1, c: 3}
  """
  @spec drop(am, Enumerable.t(), keyword) :: am
  def drop(am, keys, opts \\ [cast: true]) do
    opts = Keyword.put_new(opts, :cast, true)

    Multi.get_and_update(
      am,
      keys,
      fn _ -> {:_done, :drop} end,
      opts
    )

    am
  end


  ##
  ## TO_MAP / TAKE
  ##

  @doc """
  Returns a *current* `Map` representation.

  ## Examples

      iex> %{a: 1, b: 2, c: nil}
      ...> |> AgentMap.new()
      iex> |> to_map()
      %{a: 1, b: 2, c: nil}

  This call returns a representation at the moment, so any pending operations
  will have no effect:

      iex> %{a: 1, b: 2, c: nil}
      ...> |> AgentMap.new()
      ...> |> sleep(:a, 20)         # 0a     — spawns a worker for the :ay
      ...> |> put(:a, 42, !: :avg)  #  ↳ 1a  — delayed for 20 ms
      ...>                          #
      ...> |> to_map()              # 0
      %{a: 1, b: 2, c: nil}
  """
  @spec to_map(am) :: %{required(key) => value}
  def to_map(am) do
    _call(am, %Req{act: :to_map}, timeout: 5000)
  end

  @doc """
  Returns a map with `keys` and *current* values.

  ## Options

    * `!: priority`, `:now`;

    * `:timeout`, `5000`.

  ## Examples

      iex> %{a: 1, b: 2, c: 3}
      ...> |> AgentMap.new()
      ...> |> put(:a, 42)
      ...> |> put(:b, 42)
      ...> |> take([:a, :b, :d])
      %{a: 42, b: 42}

  This call returns a representation at the moment, so any pending operations
  will have no effect:

      iex> am =
      ...>   AgentMap.new(a: 1, b: 2, c: 3)
      iex> am
      ...> |> sleep(:a, 20)             # 0a         — spawns a worker for the :a key
      ...> |> put(:a, 42)               #  ↳ 1a ┐      …pending
      ...>                              #       :
      ...> |> put(:b, 42)               # 0b    :    — is performed on the server
      ...> |> take([:a, :b])            # 0     :
      %{a: 1, b: 42}                    #       :
      #                                         :
      iex> take(am, [:a, :b], !: :avg)  #       ↳ 2
      %{a: 42, b: 42}
  """
  @spec take(am, [key], keyword | timeout) :: map
  def take(am, keys, opts \\ [!: :now])

  def take(am, keys, t) when is_timeout(t) do
    take(am, keys, timeout: t)
  end

  def take(am, keys, opts) do
    _call(am, %Multi.Req{get: keys}, opts, !: :now)
  end


  ##
  ## CAST
  ##

  @doc """
  Performs "fire and forget" `update/4` call with `GenServer.cast/2`.

  Returns without waiting for the actual update to finish.

  ## Options

    * `:initial`, `nil` — value for `key` if it’s missing;

    * `!: priority`, `:avg`;

    * `tiny: true` — to execute `fun` on [server](#module-how-it-works) if it's
      possible.

  ## Examples

      iex> AgentMap.new(a: 1)
      ...> |> sleep(:a, 20)                     # 0 — creates a worker
      ...> |> cast(:a, fn 2 -> 3 end)           # : ↱ 2
      ...> |> cast(:a, fn 1 -> 2 end, !: :max)  # ↳ 1 :
      ...> |> cast(:a, fn 3 -> 4 end, !: :min)  #     ↳ 3
      ...> |> get(:a)                           #       ↳ 4
      4
  """
  @spec cast(am, key, (value | initial -> value), keyword) :: am
  def cast(am, key, fun, opts \\ [!: :avg]) do
    opts =
      opts
      |> Keyword.put_new(:!, :avg)
      |> Keyword.put_new(:cast, true)

    update(am, key, fun, opts)
  end
end

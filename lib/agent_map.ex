defmodule AgentMap do
  require Logger


  defstruct [
    :backend,
    :proxy,
    metadata: :__inline__
  ]

  @typedoc """
  All information about the storage is combined in `AgentMap` struct. It
  contains:

    * `ETS` identifier;
    * proxy PID [if any];
    * metadata [if any].

  As `ETS` tables are only available on local nodes, a special process is needed
  to access (or metadata) them from remote nodes. See `AgentMap.Proxy` for the
  details. As so, on the remote nodes only `:proxy` field is needed.

  `Enumerable` and `Collectable` protocols are implemented:

      iex> am = AgentMap.new(a: 1, c: 4)
      iex> %{a: 2, b: 3}
      ...> |> Enum.into(am)     # `Collectable` protocol
      ...> |> to_map()
      %{a: 2, b: 3, c: 4}
      #
      iex> Enum.count(am)       # `Enumerable` protocol
      3


      #
      iex> am
      ...> |> put(:a, & &1 + 1) # direct call to ETS is made
      ...> |> get(:a)           # …the same
      3


      iex> {:ok, pid}
      ...>   = AgentMap.Proxy.start_link()
      ...>
      iex> am = AgentMap.new(pid)
      ...>
      iex> is_pid(am.backend)
      true

  Using `metadata: :__inline__` (by default) makes it store metadata as a `Map`
  inside the `ETS`/`DETS` table under `:__metadata__` key.

  `ETS` identifier is provided if the struct is used on the local node.
  """

  alias AgentMap.{Req, Multi, Proxy, Storage, Utils}

  import Storage, only: [prep!: 1]

  @moduledoc """
  `AgentMap` is a thin layer on top of `ETS` that provides `Map`-like interface:

      iex> import AgentMap

      iex> :ets.new(:table, [])
      ...> |> put(:key, :value)
      ...> |> get(:key)
      :value

      iex> ets = :ets.new(:table, [:bag])
      iex> ets
      ...> |> put(:key, :value1)
      ...> |> put(:key, :value2)
      ...> |> put(:key, [:value3, :value4])
      ...> |> get(:key)
      [:value1, :value2, [:value3, :value4]]
      iex> delete(ets)
      :ok

  All functions supports raw `ETS` and `DETS` tables to be passed as an
  argument.

  It can also act as a storage that provides:

    * concurrent write access for each key with prioritization and [multi-key
      operations](AgentMap.Multi.html);
    * access from remote nodes (see `AgentMap.Proxy`);
    * metadata storage (see `#Metadata`).


  Storage does not use any type of the coordinating process to handle calls.
  Although, to control its lifecycle a simple `GenServer` process can be started
  via the `start/2` or `start_link/2` functions.



  See [README](readme.html#examples) for memoization and accounting examples.

  ## Using as a kinky thin `Map`-interface

  ## Using as a shareable `Map`

  Create and use it as you use an ordinary `Map` (`new/0`, `new/2`):

      iex> am = AgentMap.new(a: 42, b: 24)
      ...>
      iex> get(am, :a)
      42
      iex> keys(am)
      [:a, :b]
      iex> am
      ...> |> update(:a, & &1 + 1)
      ...> |> update(:b, & &1 - 1)
      ...> |> to_map()
      %{a: 43, b: 23}
      #
      iex> Enum.count(am)
      2

  Pass to another process and change values simultaniously.

  It allows to solve readers-writers problem in a simple manner.
  It allows multiple processes to write to the same key at once.


  It supports parallel single and [multi-key operations](AgentMap.Multi.html),
  prioritization, metadata and access from remote nodes.

  It can be used for any purposes where usual `ets` and `dets` are used, such as
  name lookups (using the :via option), storing properties, custom dispatching
  rules, or a pubsub implementation. We explore some of those use cases below.

  In this case `AgentMap` works as a simple `ETS` wrapper. No processes is
  spawned and storage is available only for the processes on the local node.

  ## Proxy access

  To make the storage accessable to processes on remote nodes use
  `Proxy.start/2` and `Proxy.start_link/2` functions. It works the same way:

      iex> {:ok, pid} = AgentMap.Proxy.start_link()
      iex> pid
      ...> |> put(:a, 1)
      ...> |> get(:a)
      1

  Use `wrap/1` to use `Enumerable` and `Collectable` protocols:

      iex> {:ok, pid} = AgentMap.start_link() # creates ETS
      iex> Enum.empty?(wrap(pid))
      true

  To control lifecycle or to take calls from remote nodes a special `GenServer`
  process must be started (see `start_link/2`).

  This process can act as an owner for the `ETS` backend.

  ## How it works?

  When a call that change value is made for a `:key` (`update/4`,
  `get_and_update/4`, …) a temporary worker-process is spawned for this `:key`.
  While this process is alive, all requests are forwarded to its message queue.
  Each worker respects the order of incoming calls and executes them in a
  sequence, except for series of `get/4` calls. Since this type of call does not
  change value, it can be processed in parallel (see `get/3`).

  By default, each worker will die after `~20` ms of inactivity (see
  `Utils.meta/2`).

  For example:

      iex> am = AgentMap.new(a: 1)   # new ets table was created
      ...>                           # no additional processes
      iex> am
      ...> |> cast(:a, & &1 * 2)     # spawns new worker for `:a`
      ...>                           # …and adds `& &1 * 2` to its queue
      ...> |> get(:a)                # = get(:a, & &1), adds `& &1` to the queue
      2                              # queue is empty
      iex> sleep(40)                 # worker is inactive for > 20 ms
      ...>                           # …so it dies :'(
      iex> get(am, :a, & &1 * 4)     # `& &1 * 4` is executed in a separate `Task`…
      ...>                           # …no worker is spawned
      8

  When a worker process is started for a `:key`, the `{:key, value, pid}` tuple
  is used. Also, `{:key, value, key_metadata}` and `{:key, value, pid,
  key_metadata}` is in use.



  Basic operations `get/3`, `fetch/3`, `put/4` and `replace!/4` are implemented
  as a simple wrappers and as so have nearly zero overhead.

  For the basic read-write operations, interface wraps corresponding backend
  calls. So, for example `put/3` call to `ETS` will be `:ets.insert/2`.

  ## Use cases

  ### `Map`-like thin interface for `ETS` and `DETS`.

  Most of the functions that works with the raw `ets` and `dets` are:

    * `delete/1`, `delete/2`, `drop/2`; `equal?/2`; `fetch/2`, `fetch!/2`,
    * `get/3`; `get_and_update/3`, `get_and_update!/3`, `get_lazy/3`;
    * `pop/3`, `pop_lazy/3`;
    * `has_key?/2`, `keys/1`; `put/3`, `put_new/3`, `put_new_lazy/3`, `split/3`;
    * `take/3`, `to_list/1`, `update/4`, `update!/3`, `values/1`;
    * `merge/2`, `merge/3`.

  and `wrap/1` that wraps `ets` in the `AgentMap` struct and as so allows to use
  it with `Enumerable`, `Collectable` and `Access` protocols and store metadata.

  Example:

      iex> ets = :ets.new()

      iex> ets.delete
      iex> am = AgentMap.new(a: 1)   # no server
      iex> am
      ...> |> cast(:a, & &1 * 2)     # spawns new worker for `:a`
      ...>                           # …and adds `& &1 * 2` to its queue
      ...> |> get(:a)                # = get(:a, & &1), adds `& &1` to the queue
      2                              # queue is empty
      iex> sleep(40)                 # worker is inactive for > 20 ms
      ...>                           # …so it dies :'(
      iex> get(am, :a, & &1 * 4)     # `& &1 * 4` is executed in a separate `Task`…
      ...>                           # …no worker is spawned
      8

  ### Priority (`:!`)

  Most of the functions support `!: priority` option to make out-of-turn
  ("priority") calls.

  Priority can be given as a non-negative integer or alias. Aliases are: `:min |
  :low` = `0`, `:avg | :mid` = `255`, `:max | :high` = `65535`. Relative value
  are also acceptable, for ex.: `{:max, -1}` = `65534`.

      iex> AgentMap.new(state: :ready)
      ...> |> sleep(:state, 10)                                       # 0 — creates a 💤-worker
      ...> |> cast(:state, fn :go!    -> :stop   end)                 # :   ↱ 3
      ...> |> cast(:state, fn :steady -> :go!    end, !: :max)        # : ↱ 2 :
      ...> |> cast(:state, fn :ready  -> :steady end, !: {:max, +1})  # ↳ 1   :
      ...> |> get(:state)                                             #       ↳ 4
      :stop

  Also, `!: :now` option can be provided to use *current* value for a `:key`
  and, as so, return immediately. Some calls (`fetch!/3`, `fetch/3`, `values/2`,
  `to_map/2`, `has_key?/3` and `take/3`) use this by default:

      iex> am =
      ...>   AgentMap.new(key: 1)
      iex> am
      ...> |> sleep(:key, 20)                 # 0        — creates a 💤-worker
      ...> |> put(:key, 42)                   # ↳ 1 ┐
      ...>                                    #     :
      ...> |> fetch(:key)                     # 0   :
      {:ok, 1}                                #     :
      iex> get(am, :key, & &1 * 42)           #     ↳ 2
      1764
  """

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

  @type ets :: reference
  @type dets :: atom

  @doc false
  defguard is_timeout(t)
           when (is_integer(t) and t > 0) or t == :infinity

  # https://github.com/elixir-lang/elixir/blob/79388035f5391f0a283a48fba792ae3b4f4b5f21/lib/elixir/lib/agent.ex#L201

  @doc false
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      if Module.get_attribute(__MODULE__, :doc) == nil do
        @doc """
        Returns a specification to start this module under a supervisor.
        See `Supervisor`.
        """
      end

      def child_spec(args) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [args]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      defoverridable child_spec: 1
    end
  end

  #

  # @doc false
  # def _call(am, req, opts \\ [])

  # def _call(%_{server: _} = am, req, opts) do
  #   _call(am.server, req, opts)
  # end

  # def _call(am, req, opts) do
  #   opts = Keyword.put_new(opts, :initial, opts[:default])

  #   req = struct(req, opts)
  #   pid = (is_map(am) && am.server) || am

  #   if opts[:cast] do
  #     GenServer.cast(pid, req)
  #     am
  #   else
  #     GenServer.call(pid, req, opts[:timeout] || 5000)
  #   end
  # end

  # @doc false
  # def _call(am, req, opts, defs) do
  #   _call(am, req, Keyword.merge(defs, opts))
  # end

  ##   ## ##  ####  ####    ####  ## ##  ####  ##    ####
  ##    ###   ###   ###     ##     ###   ##    ##    ###
  ####   #    ##    ####    ####    #    ####  ####  ####

  ## NEW / NEW!
  ## DELETE
  ## WRAP

  ##
  ## NEW / DELETE
  ##

  @doc """
  Creates a new `ETS` from `data` and returns `AgentMap` [struct](?TODO).
  Duplicated keys are removed; the latest one prevails.

  Caller creates `ETS` instance with `:ets.new(:table, [])` and ownes the table.
  No processes is spawned and the table will be accessible only from the local
  node.

  See `new!/2`, `delete/1`, `wrap/1` and `Proxy.start_link/2`.

  ## Examples

      iex> AgentMap.new()
      ...> |> put(:key, :value)
      ...> |> get(:key)
      :value

  `AgentMap` struct implements `Enumerable`:

      iex> AgentMap.new()
      ...> |> put(:key, :value)
      ...> |> Enum.empty?()
      false

   and `Collectable` protocols:

      iex> am = AgentMap.new()
      iex> Enum.into(%{a: 1, b: 2}, am)
      iex> get(am, :a)
      1
  """
  @spec new(Enumerable.t) :: am
  def new(data \\ %{}), do: new!(data, [])

  @doc """
  Creates a new storage with the given backend and `data` and returns `AgentMap`
  [struct](#?).

  If `ETS` or `DETS` type is a "set", duplicated keys are removed; the latest
  one prevails.

  Storage does not need to start any coordinating process to handle calls. The
  table will be accessible only from the local node.

  See `new/1`, `delete/1`, `wrap/1` and `Proxy.start_link/2`.

  ## Options

  ### Backend

    * `backend: ETS`, `ETS` — to start a new storage with the
      `:ets.new(:__data__, [])`;

    * `backend: {ETS | DETS, storage.opts}` — to make tweaks.

  ### Metadata

  Metadata can be stored as a separate `ETS` / `DETS` or within the backend
  storage under the `:__meta__` key. By default, the metadata is not stored but
  if the metadata is provided via the `meta` option or `Utils.meta/2`,
  `:__meta__` is used:

    * `meta`, `[]` — a keyword list of metadata to be stored (see
      `Utils.meta/2`).

      Storage recognizes the following parameters:

      ** `max_concurrency: pos_integer | :infinity`, `:infinity` — to set up a
         maximum number of processes could operate concurrently. By default, no
         limit is set;

      ** `wait_time`, `20` — by default, workers dies after `20` ms of
         inactivity.

    * `metadata: :__meta__` — to store metadata under the `:__meta__` key within
      the backend storage;

    * `metadata: ETS` — to store metadata as a separate `ETS` that is created
      with `:ets.new(:__meta__, [])`;

    * `metadata: {ETS | DETS, storage.opts}` — to select other storage options.

  No metadata is stored if `meta` and `metadata` attributes are missing. It can
  be created later with the `Utils.meta/2`.

  ### Storage

  Storage opts for `ETS` are:

    * `name: :atom`, `false` — to create `:named_table`;
    * `type: :set | :ordered_set | :bag | :duplicated_bag`, `:set`;
    * `access: :public | :protected | :private`, `:public`;
    * `compressed: boolean`, `false`;
    * `read_concurrency | write_concurrency : boolean`, `false`;
    * `keypos: integer ≥ 1`, `1`;
    * `heir: {pid, heir_data :: term} | :none`, `:none`.

  See [ETS docs](http://erlang.org/doc/man/ets.html#new-2) or `Storage.ETS` for
  the details.

  Storage opts for `DETS` are:

    * `type: :bag | :duplicated_bag | :set`, `:set`;
    * `file: Path.t`, `table_name`;
    * `access: :read | :read_write`, `:read_write`;
    * `auto_save: integer ≥ 0 | :infinity`, `180_000`;
    * `min_no_slots: :default | integer ≥ 0`, `256` — the estimated number of
      different keys to be stored in the table;
    * `max_no_slots: :default | integer ≥ 0`, `32_000_000` — the maximum number
      of slots to be used;
    * `keypos: integer ≥ 1`, `1`;
    * `ram_file: boolean`, `false` — whether the table is to be kept in RAM;
    * `repair: boolean | :force`, `true` — specifies if the DETS server is to
      invoke the automatic file reparation algorithm.

  See [DETS docs](http://erlang.org/doc/man/dets.html#open-file-2) or
  `Storage.DETS` for the details.

  ## Examples

  `AgentMap` struct implements `Collectable` protocol:

      iex> {:ok, pid}
      ...>   = AgentMap.start_link()
      ...>
      iex> am = AgentMap.new(pid)
      ...>
      iex> %{a: 2, b: 3}
      ...> |> Enum.into(am)
      ...> |> to_map()
      %{a: 2, b: 3}

  By default, metadata is stored within the storage under the `:__meta__` key:

      iex> am = AgentMap.new()
      iex> am[:__meta__]
      nil
      iex> put_meta(am, :key, :value)
      iex> am[:__meta__]
      %{key: :value}

      iex> am = AgentMap.new(%{}, meta: [key: :value])
      iex> meta(am, :key)
      :value
      iex> am
      ...> |> put_meta(:key, :new_value)
      ...> |> meta(:key)
      :new_value
      iex> am[:__meta__]
      %{key: :new_value}
  """
  @spec new!(Enumerable.t, keyword) :: am
  def new!(%AgentMap{} = am, opts \\ [])

  # TODO: why?
  def new!(%AgentMap{} = am, _opts) do
    raise ArgumentError, message: "#{inspect(am)} cannot be provided as an argument"
  end

  def new!(%_{} = s, opts) do
    new(Map.from_struct(s), opts)
  end

  def new!(data, opts) when is_map(m) do
    # prepair storage (and metadata)

    s = Storage.prep!(opts[:storage] || ETS)

    for {k, v} <- Map.new(data) do
      Storage.insert(s, k, v)
    end

    opts =
      opts
      |> Keyword.put_new(:wait_time, 20)
      |> Keyword.put_new(:max_c, opts[:max_concurrency] || :infinity)

    m =
      m
      |> Map.put_new(:wait_time, opts[:wait_time] || 20)
      |> Map.put_new(:max_c, opts[:max_c] || opts[:max_concurrency] || :infinity)
      |> Storage.initialize_meta(storage: s)

    am = %AgentMap{storage: s, metadata: m}

    if opts[:max_c] == :infinity && opts[:wait_time] == 20 do
      am
    else
      am
      |> AgentMap.Utils.put_meta(:max_c, opts[:max_c])
      |> AgentMap.Utils.put_meta(:wait_time, opts[:wait_time])
    end
  end

  #TODO: delete DETS
  #TODO: close DETS

  @doc """
  Deletes backend storage.

  Translates to the `:ets.delete/1` and `:dets.close/1` calls respectively.

  Returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> am = AgentMap.new(%{a: 1, b: 2})
      iex> get(am, :a)
      1
      iex> delete(am)
      :ok
      iex> get(am, :a)
      ** (Error) No storage
  """
  @spec delete(am) :: :ok | {:error, reason}
  def delete(%AgentMap{} = am), do: delete(am.backend)

  @spec delete(ets | dets | raw) :: :ok | {:error, reason}
  def delete(raw), do: Storage.delete(raw)

  ##
  ## WRAP
  ##

  @doc """
  Wraps given `pid` of the instance into `AgentMap` struct. Instance can be
  spawned with `start_link/2` or `start/2`. This struct allows to use
  `Enumerable` and `Collectable` protocols, and speeds up making local-node
  calls.

  The `AgentMap` struct holds link to the `storage` and `metadata` tables. As
  so, basic operations on the underlying `ETS`/`DETS` tables are made directly,
  with nearly zero-cost.

  ## Examples

  Any `pid` of the already started instance can be wrapped into `AgentMap`
  struct:

      iex> {:ok, pid}
      ...>   = AgentMap.start_link()
      ...>
      iex> put(pid, :a, 1)
      ...>
      iex> %_{server: ^pid} = am = AgentMap.wrap(pid)
      ...>
      iex> Enum.empty?(am)
      false
      iex> get(am, :a)
      1
  """
  @spec wrap(am) :: am
  def wrap(%AgentMap{} = am), do: am

  @spec wrap(pid) :: am
  def wrap(proxy) when is_pid(proxy) do
    GenServer.call(proxy, :get_state, 20)
  end

  @spec wrap(ets | dets | storage) :: am
  def wrap(storage), do: %AgentMap{backend: storage}

  @doc """
  Wraps given `pid` of the instance into `AgentMap` struct. Instance can be
  spawned with `start_link/2` or `start/2`. This struct allows to use
  `Enumerable` and `Collectable` protocols, and speeds up making local-node
  calls.

  The `AgentMap` struct holds link to the `storage` and `metadata` tables. As
  so, basic operations on the underlying `ETS`/`DETS` tables are made directly,
  with nearly zero-cost.

  ## Examples

  Any `pid` of the already started instance can be wrapped into `AgentMap`
  struct:

      iex> {:ok, pid}
      ...>   = AgentMap.start_link()
      ...>
      iex> put(pid, :a, 1)
      ...>
      iex> %_{server: ^pid} = am = AgentMap.wrap(pid)
      ...>
      iex> Enum.empty?(am)
      false
      iex> get(am, :a)
      1
  """
  @spec wrap(pid | am) :: am
  def wrap(proxy) when is_pid(proxy) do
    if local_pid?(proxy) do
      {storage, metadata} = GenProxy.call(proxy, :get_state)

      %AgentMap{
        proxy: proxy,
        backend: storage,
        metadata: metadata
      }
    else
      %AgentMap{
        proxy: proxy
      }
    end
  end

  def wrap(%AgentMap{} = am), do: am

  ##
  ## CHILD_SPEC
  ##

  @doc since: "1.1.2"
  @doc """
  See the "Child specification" section in the `Supervisor` module for more
  detailed information.
  """
  def child_spec([funs, opts]) when is_list(funs) and is_list(opts) do
    %{
      id: AgentMap,
      start: {AgentMap, :start_link, [funs, opts]}
    }
  end

  def child_spec([funs]), do: child_spec([funs, []])

  ##
  ## GET / GET_LAZY / FETCH / FETCH!
  ##

  @doc """
  Gets a value via the given `fun`.

  A callback `fun` is sent to an instance that invokes it, passing as an
  argument the value associated with `key`. The result of an invocation is
  returned from this function.

  This call does not change value, and so, workers can execute a series of
  `get`-calls in separate `Task`s.

  To prevent over-spawning while handling long series of `get`-calls:

    1. each worker by default is limited to spawn no more than `3`
       `Task`-processes (see `Utils.meta/2`);

    2. `tiny: true` option can be provided for `get`-calls.

  ## Options

    * `:default`, `nil` — value for `key` if it's missing;

    * `!: priority`, `:avg`;

    * `tiny: true` — prevents worker from spawning a separate `Task` to execute
      `fun` callback;

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

  # TODO: understand why I commented it :) Ko-o-otik :)

  # def get(pid, k, f, opts) when is_pid(pid) do
  #   req = %Req{act: :get, key: k, fun: f}
  #   _call(am, req, opts, !: :avg)
  # end

  def get(%AgentMap{storage: s} = am, k, f, opts) do
    worker = Storage.get_worker(s, k)

    if worker do
      send(worker, %{act: :get, fun: f})

      timeout = opts[:timeout] || 5000

      receive do
        reply ->
          nil
      after
        min(timeout, 100) ->
          worker = Storage.get_worker(s, k)
      end
    else
    end
  end

  @doc """
  Returns the value for a specific `key`.

  This call has the `:min` priority. Thus, by default, the value is retrived
  only after all other calls for `key` are completed.

  See `get/4`, `AgentMap.Multi.get/3`.

  ## Options

    * `:default`, `nil` — value to return if `key` is missing;

    * `!: priority | :now`, `:min`;

    * `:timeout`, `5000`.

  ## Examples

      iex> am = AgentMap.new(Alice: 42)
      iex> get(am, :Alice)
      42
      iex> get(am, :Bob)
      nil
      iex> get(am, :Bob, default: 42)
      42

  By default, `get/4` has the `:min`
  priority:

      iex> AgentMap.new(a: 42)
      ...> |> sleep(:a, 20)           # creates a worker, sleeps
      ...> |> put(:a, 0)              # changes value  — !: :max
      ...> |> get(:a)                 # returns value  — !: :min
      0

      iex> AgentMap.new(a: 42)
      ...> |> sleep(:a, 20)           # 0
      ...> |> put(:a, 0)              # : ↱ 2  — !: :max
      ...> |> get(:a, !: {:max, +1})  # ↳ 1    — !: {:max, +1}
      42
  """
  @spec get(am, key, keyword) :: value | default
  def get(am, key, opts \\ [!: :min])

  def get(am, key, opts) when is_list(opts) do
    opts =
      opts
      |> Keyword.put_new(:!, :min)
      |> Keyword.put(:tiny, true)

    if opts[:!] == :now do
      case fetch(am, key) do
        
      get(am, key, & &1, opts)
      end
    else
      get(am, key, & &1, opts)
    end
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
  #     value) spawned from proxy;

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
  Fetches the *current* value for a specific `key`.

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
    

    if opts[:!] == :now do
      
    else
      # just forward to `get` :)
      fetch =
        fn value, exist? ->
          (exist? && {:ok, value}) || :error
        end

      opts =
        opts
        |> Keyword.put(:tiny, true)
        |> Keyword.put(:fun_arity, 2)

      get(am, key, fetch, opts)
    end
  end

  @doc """
  Fetches the value for a specific `key`, erroring out if instance doesn't
  contain `key`.

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
      {:ok, value} -> value
      :error -> raise KeyError, key: key
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

    * `tiny: true` — to execute `fun` on [proxy](#module-how-it-works) if it's
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
    req = %Req{act: :get_upd, key: k, fun: f}

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

    * `tiny: true` — to execute `fun` on [proxy](#module-how-it-works) if it's
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

    * `tiny: true` — to execute `fun` on [proxy](#module-how-it-works) if it's
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

    case get_and_update(am, key, fun, [{:fun_arity, 2} | opts]) do
      :ok -> an
      :error -> raise KeyError, key: key
    end
  end

  @doc """
  Alters the value stored under `key`.

  If `key` is not present then the `KeyError` exception is raised.

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
    _call(am, %Req{act: :keys})
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
    _call(am, %Req{act: :values})
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

      iex> AgentMap.new(a: 42)     #                 proxy    worker  queue
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

    * `tiny: true` — to execute `fun` on [proxy](#module-how-it-works) if it's
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
      |> Keyword.put(:fun_arity, 2)

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

    get_and_update(am, key, fn _ -> :pop end, opts)
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
    opts =
      opts
      |> Keyword.put_new(:cast, true)
      |> Keyword.put(:upd, keys)

    Multi.call(am, fn %{} -> {:_ret, :drop} end, opts)
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
    _call(am, %Req{act: :to_map})
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
      ...> |> put(:b, 42)               # 0b    :    — is performed on the proxy
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
    opts =
      opts
      |> Keyword.put_new(opts, :!, :now)
      |> Keyword.put(:get, keys)

    Multi.call(am, &{&1, :id}, opts)
  end

  ##
  ## CAST
  ##

  @doc """
  Performs "fire and forget" `update/4` call with `GenProxy.cast/2`.

  Returns without waiting for the actual update to finish.

  ## Options

    * `:initial`, `nil` — value for `key` if it’s missing;

    * `!: priority`, `:avg`;

    * `tiny: true` — to execute `fun` on [proxy](#module-how-it-works) if it's
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
    update(am, key, fun, Keyword.put_new(opts, :cast, true))
  end
end

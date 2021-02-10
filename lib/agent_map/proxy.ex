defmodule AgentMap.Proxy do
  use GenServer

  @moduledoc """
  Proxy process for the `AgentMap`.

  This process gaves a remote access to `ETS`.

  ## Other

  `AgentMap` is bound to the same name registration rules as `GenServer`s, see
  documentation for details.

  Note that `use AgentMap` defines a `child_spec/1` function, allowing the
  defined module to be put under a supervision tree. The generated
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

  require Logger

  import Enum, only: [map: 2, zip: 2, empty?: 1]

  ##   ##   ## ##  ####  ####    ####  ## ##  ####  ##    ####
  ##   ##    ###   ###   ###     ##     ###   ##    ##    ###
  ##   ####   #    ##    ####    ####    #    ####  ####  ####

  ## START_LINK / START
  ## STOP

  ##
  ## START / START_LINK / STOP
  ##

  @doc """
  Storage does not need any type of coordinating process to handle calls,
  but it's convenient to have a process that controls the lifecycle.

  This function creates a "proxy" that acts as a process that:

    1. owns and initializes the backend;
    2. "proxy" potential calls from the remote nodes.


  All arguments are the same except for the

  Argument `funs` is a keyword that contains pairs `{key, fun/0}`. Each `fun` is
  executed in a separate `Task` and return an initial value for `key`.

  ## Options

    See `new/2`, plus `GenServer.options` `:name`, `:timeout`, `:debug`,
      `:spawn_opt`, `:hibernate_after`:

    * `name: term` — is used for registration as described in the module
      documentation;

    * `:timeout`, `5000` — number of milliseconds is allowed to spend on the
       whole process of initialization before function terminates and returns
       `{:error, :timeout}`;

    * `:debug` — is used to invoke the corresponding function in [`:sys`
      module](http://www.erlang.org/doc/man/sys.html);

    * `:spawn_opt` — is passed as options to the underlying process as in
      `Process.spawn/4`;

    * `:hibernate_after` — if present, the `GenServer` process awaits any
      message for the given number of milliseconds and if no message is
      received, the process goes into hibernation automatically (by calling
      `:proc_lib.hibernate/3`).

  ## Return values

  If an instance is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the proxy process that owns,
  initialize and sharing table with remote nodes. If a proxy with the specified
  name already exists, the function returns `{:error, {:already_started, pid}}`
  with the PID of that process.

  If one of the callbacks fails, the function returns `{:error, [{key,
  reason}]}`, where `reason` is `:timeout`, `:badfun`, `:badarity`, `{:exit,
  reason}` or an arbitrary exception.

  ## Examples

  To start proxy with a single key `:k`.

      iex> {:ok, pid} =
      ...>   AgentMap.start_link(k: fn -> 42 end)
      iex> get(pid, :k)
      42
      iex> meta(pid, :max_concurrency)
      :infinity

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

  To start proxy without any keys use:

      iex> AgentMap.start([], name: Account)
      iex> Account
      ...> |> put(:a, 42)
      ...> |> get(:a)
      42

  # TODO: test global name resolution
  """
  @spec start_link([{key, (() -> any)}], keyword | timeout) :: on_start
  @spec start_link(ets | dets | storage, keyword) :: on_start
  @spec start_link(am) :: on_start
  def start_link(funs \\ [], opts \\ [max_concurrency: @max_c])

  def start_link(funs, opts) do
    args = Storage.prep!(opts)
    args = Metadata.prep!(opts)

    GenServer.start_link(AgentMap.Proxy, args, opts)
  end

  def start_link(storage, opts) do
  end

  def start_link(%AgentMap{} = am) do
    if am.proxy && Process.alive?(am.proxy) do
      Logger.warn("AgentMap proxy process is already started (#{inspect(am.proxy)}).")

      {:ok, am.proxy}
    else
      GenServer.start_link()

    end

    start_link()
  end

  @doc """
  Starts an unlinked proxy process.

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
  @spec start([{key, (() -> any)}], keyword) :: on_start
  def start(funs \\ [], opts \\ [max_concurrency: @max_c, storage: ETS]) do
    args = [
      funs: funs,
      timeout: opts[:timeout] || 5000,
      max_c: opts[:max_c] || opts[:max_concurrency] || :infinity,
      meta: opts[:meta] || [],
      storage: prep!(:storage, opts[:storage] || ETS)
    ]

    # Global timeout must be turned off.
    opts = Keyword.put(opts, :timeout, :infinity)

    if opts[:link] do
      GenServer.start_link(AgentMap.Proxy, args, opts)
    else
      GenServer.start(AgentMap.Proxy, args, opts)
    end
  end

  ##
  ## STOP
  ##

  @doc """
  Synchronously stops the proxy with the given `reason`.

  Returns `:ok` if terminated with the given reason. If it terminates with
  another reason, the call will exit.

  This function keeps OTP semantics regarding error reporting. If the reason is
  any other than `:normal`, `:shutdown` or `{:shutdown, _}`, an error report
  will be logged.

  # TODO:
  `DETS` tables are closed with `:dets.close/1`.

  ### Examples

      iex> {:ok, pid} = AgentMap.Proxy.start_link()
      iex> AgentMap.Proxy.stop(pid)
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
  ##
  ##

  ##
  ## HELPERS
  ##
  defp run({m, f, args}, extra), do: apply(m, f, extra ++ args)
  defp run(fun, extra), do: apply(fun, extra)

  ##
  ## CALLBACKS
  ##

  @impl true
  def init({_storage, _metadata} = state) do
    {:ok, state}
  end

  def init(args) do
    timeout = args[:timeout]

    keys = Keyword.keys(args[:funs])

    results =
      args[:funs]
      |> map(fn {_key, fun} ->
        Task.async(fn ->
          try do
            {:ok, run(fun, [])}
          rescue
            BadFunctionError ->
              {:error, :badfun}

            BadArityError ->
              {:error, :badarity}

            exception ->
              {:error, {exception, __STACKTRACE__}}
          end
        end)
      end)
      |> Task.yield_many(timeout)
      |> map(fn {task, res} ->
        res || Task.shutdown(task, :brutal_kill)
      end)
      |> map(fn
        {:ok, result} ->
          result

        {:exit, _reason} = e ->
          {:error, e}

        nil ->
          {:error, :timeout}
      end)
      |> zip(keys)

    errors =
      for {{:error, reason}, key} <- results do
        {key, reason}
      end

    if empty?(errors) do
      meta = :ets.new(:metadata, read_concurrency: true)
      storage = args[:storage]

      meta =
      |> Storage.new()
      |> Storage.put(:processes, args[:processes])
      |> Storage.put(:storage, storage)
      |> Storage.put(:max_c, args[:max_c])

      for {{:ok, v}, key} <- results do
        put(storage, key, v)
      end

      {:ok, {storage, meta}}
    else
      {:stop, errors}
    end
  end

  @impl true
  def handle_call(:get_state, {from, _tag}, {storage, metadata} = state) do
    if node(from) == node() do
      # local call
      %AgentMap{
        proxy: self(),
        backend: storage,
        metadata: metadata
      }
    else
      %AgentMap{
        proxy: self()
      }
    end

    {:reply, state}
  end

  alias :ets, as: ETS
  alias AgentMap.{Worker, Multi, Server}

  import Worker, only: [dict: 1, dec: 1, dec: 2, inc: 2]
  import Server.Storage, only: [insert: 3, get: 3, get: 2]

  # def spawn_worker({values, workers} = state, key, quota \\ 1) do
  #   if Map.has_key?(workers, key) do
  #     state
  #   else
  #     value? =
  #       case Map.fetch(values, key) do
  #         {:ok, value} ->
  #           {value}

  #         :error ->
  #           nil
  #       end

  #     server = self()
  #     ref = make_ref()

  #     pid =
  #       spawn_link(fn ->
  #         Worker.loop({ref, server}, value?, quota)
  #       end)

  #     # hold …
  #     receive do
  #       {^ref, :resume} ->
  #         :_ok
  #     end

  #     # reserve quota
  #     inc(:processes, quota)

  #     #
  #     {Map.delete(values, key), Map.put(workers, key, pid)}
  #   end
  # end

  def spawn_worker({storage, meta} = state, key, quota \\ 1) do
    if get_worker(storage, key) do
      state
    else
      server = self()
      ref = make_ref()

      pid =
        spawn_link(fn ->
          Worker.loop({ref, server}, quota)
        end)

      # hold …
      receive do
        {^ref, :resume} ->
          :_ok
      end

      # reserve quota
      inc({ETS, meta}, :processes, quota)

      #
      {Map.delete(values, key), Map.put(workers, key, pid)}
    end
  end

  def extract_state({:noreply, state}), do: state
  def extract_state({:reply, _get, state}), do: state

  ##
  ## CALL / CAST
  ##

  @impl true
  # Agent.get(am, f):
  def handle_call({:get, f}, from, state) do
    req =
      struct(Multi.Req, %{
        get: :all,
        upd: [],
        fun: &{run(f, [&1]), :id},
        !: :avg
      })

    handle_call(req, from, state)
  end

  # Agent.update(am, f):
  def handle_call({:update, f}, from, state) do
    fun = &{:ok, run(f, [&1])}

    handle_call({:get_and_update, fun}, from, state)
  end

  # Agent.get_and_update(am, f):
  def handle_call({:get_and_update, f}, from, state) do
    req =
      struct(Multi.Req, %{
        get: :all,
        upd: :all,
        fun: &run(f, [&1]),
        !: :avg
      })

    handle_call(req, from, state)
  end

  def handle_call(%r{} = req, from, state) do
    r.handle(%{req | from: from}, state)
  end

  @impl true
  def handle_cast({:cast, fun}, state) do
    resp = handle_call({:update, fun}, nil, state)
    {:noreply, extract_state(resp)}
  end

  def handle_cast(%_{} = req, state) do
    resp = handle_call(req, nil, state)
    {:noreply, extract_state(resp)}
  end

  ##
  ## INFO
  ##

  # TODO: REMOVE!
  # get task done its work after workers die
  @impl true
  def handle_info(%{info: :done}, {_storage, meta} = state) do
    :ets.update_counter(meta, :processes, -1)

    {:noreply, state}
  end

  # TODO: REMOVE!
  # worker asks to increase quota
  @impl true
  def handle_info({ref, worker, :more?}, {_storage, meta} = state) do
    {soft, _h} = Process.get(:max_c)

    case :ets.lookup(meta, ) do
      [{:processes, n}] when n < soft ->
        send(worker, {ref, %{act: :quota, inc: 1}})
        :ets.update_counter(meta, :processes, +1)

      _ ->
        :no
    end

    {:noreply, state}
  end

  # TODO: REWRITE!
  @impl true
  def handle_info({worker, :die?}, {storage, meta} = state) do
    # Msgs could came during a small delay between
    # :die? was sent and this call happen.
    {_, mq_len} = Process.info(worker, :message_queue_len)

    if mq_len == 0 do
      # no messages in the workers mailbox

      #!
      dict = dict(worker)
      send(worker, :die!)

      #!
      p = dict[:processes]
      q = dict[:quota]

      [[key, value?]] =
        :ets.match(storage, {:"$1", :"$2", worker})

      :ets.insert(storage, {key, value?})

      # :G:
      # values =
      #   case dict[:value?] do
      #     {value} ->
      #       Map.put(values, key, value)

      #     nil ->
      #       values
      #   end

      # return quota
      dec(meta, :processes, q - p)
    else
      send(worker, :continue)
    end

    {:noreply, state}
  end

  ##
  ## CODE CHANGE
  ##

  @impl true
  def code_change(_old, state, fun) do
    {:ok, run(fun, [state])}
  end
end

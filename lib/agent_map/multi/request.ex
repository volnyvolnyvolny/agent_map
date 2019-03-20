defmodule AgentMap.Multi.Req do
  @moduledoc false

  require Logger

  #

  @type key :: AgentMap.key()
  @type value :: AgentMap.value()
  @type cb_m :: AgentMap.cb_m()

  @typedoc """
  This struct is sent by `Multi.get_and_update/4` and `take/3`.

  Fields:

    * server: pid;
    * from: replying to;
    * !: priority to be used when collecting values;
    * get: keys whose values form a callback arg map;
    * upd: keys whose values are updated;
    * fun: callback;
    * initial: value if key is missing;
    * :timeout.
  """
  @type t ::
          %__MODULE__{
            get: [key],
            upd: [key],
            fun: cb_m,
            server: pid,
            from: GenServer.from(),
            !: non_neg_integer | :now,
            initial: value,
            timeout: timeout
          }

  defstruct [
    :fun,
    :server,
    :from,
    :initial,
    get: [],
    upd: [],
    !: :now,
    timeout: 5000
  ]

  ##
  ## *SERVER*
  ##
  ## *. ↳ handle(req, state)
  ##
  ##    Catches a request.
  ##
  ##    1. ↳ spawn_leader(req)
  ##
  ##       Spawns a *LEADER* process that is responsible for execution.
  ##
  ##    2. ↳ prepare(req, state, leader (pid))
  ##
  ##       Ensures that for each key in {req.get ∩ req.upd} is spawned a worker.
  ##       For keys in:
  ##
  ##         * {req.get ∖ req.upd} fetches values or asks workers to share them;
  ##
  ##         * {req.get ∩ req.upd} asks workers to "share their values and wait
  ##           for a further instructions".
  ##
  ##       Returns:
  ##
  ##                                     ┌———————————————┐
  ##                                     ┊  (req.upd)    ┊
  ##                                     ↓    updating   ↓
  ##                               ┌———————————————┐
  ##                               ↓    workers    ↓
  ##                                     ╔═══════════════╗
  ##         ┌─────────┬ ┌───────┬ ┌─────╫─────────┐ (L) ║
  ##         │  state  │ │ known │ │ get ║ get_upd │ upd ║
  ##         │ ({M,M}) │ │  (M)  │ │ (M) ╚═════════╪═════╝
  ##         └─────────┴ └───────┴ └───────────────┘
  ##                     ↑    callback argument    ↑
  ##                     ┊        (req.get)        ┊
  ##                     └—————————————————————————┘

  ##
  ## *LEADER*
  ##
  ## 1. ↳ collect(known, keys)
  ##
  ##    Collects data shared by workers and adds it to the `known` map.
  ##
  ## 2. ↳ req.fun
  ##
  ##    Callback can return:
  ##
  ##    * `{ret, map}` — an *explicitly* given returned value (`ret`) and
  ##      map with a new values;
  ##
  ##    * `{ret, [new value] | :drop | :id}` — an *explicitly* given returned
  ##      value (`ret`) and actions to be taken for every key in `req.upd`;
  ##
  ##    * `[{ret} | {ret, new value} | :pop | :id]` — a composed returned value
  ##      (`[ret | value]`) and individual actions to be taken;
  ##
  ##    * sugar: `{ret} ≅ {ret, :id}`, `:pop ≅ [:pop, …]`, `:id ≅ [:id, …]`.
  ##   └———————————————————┬————————————————————————————————————————————————┘
  ##                       ⮟
  ## 3. ↳ finalize(req, result, known, {get_upd (workers), upd})
  ##
  ##    Commits changes for all values. Replies.
  ##
  ##    At the moment, {req.get ∩ req.upd} workers are still waiting for
  ##    instructions to resume. From the previos steps we already {know} their
  ##    values and so we have to collect only values for keys in {req.upd ∖
  ##    req.get}.
  ##
  ##    A special `Commit` request is send to *SERVER*. It contains keys needs
  ##    to be dropped (`:drop`) and a keyword with update data (`:upd`).

  alias AgentMap.{CallbackError, Req, Server, Worker, Multi.Req.Commit}

  import Server, only: [spawn_worker: 2]
  import Worker, only: [values: 1]
  import Req, only: [reply: 2]

  import MapSet, only: [intersection: 2, difference: 2, to_list: 1]

  ##
  ## CALLBACKS
  ##

  defp share(key, value, exist?) do
    {key, if(exist?, do: {value})}
  end

  defp share_accept(key, value, exist?, opts) do
    send(opts[:from], share(key, value, exist?))

    receive do
      :drop ->
        :pop

      :id ->
        :id

      {new_value} ->
        {:_set, new_value}
    after
      opts[:timeout] || :infinity ->
        :id
    end
  end

  ##
  ## SPAWN_LEADER
  ##

  # First step is to spawn process that
  # will be responsible for handling this call.

  defp spawn_leader(req) do
    spawn_link(fn ->
      receive do
        {known, {get, get_upd, upd}} ->
          keys = Map.keys(get) ++ Map.keys(get_upd)
          known = collect(known, keys)

          ret = apply(req.fun, [known])

          finalize(req, ret, known, {get_upd, upd})
      end
    end)
  end

  ##
  ## PREPARE
  ##

  #
  # Making three disjoint sets:
  #
  #  1. keys that are only planned to collect — no need to spawn workers.
  #     Existing workers will be asked to share their values;
  #
  #  2. keys that are collected and updated — spawning workers. Workers will be
  #     asked to share their values and wait for the new ones;
  #
  #  3. keys that are only updated — no spawning.
  #
  defp sets(%{get: g, upd: u} = req, {values, workers}) when :all in [g, u] do
    all_keys = Map.keys(values) ++ Map.keys(values(workers))

    g = (g == :all && all_keys) || g
    u = (u == :all && all_keys) || u

    sets(%{req | get: g, upd: u}, :_state)
  end

  defp sets(req, _state) do
    get = MapSet.new(req.get)
    upd = MapSet.new(req.upd)

    # req.get ∩ req.upd
    get_upd = intersection(get, upd)

    # req.get ∖ req.upd
    get = difference(get, get_upd)

    # req.upd ∖ req.get
    upd = difference(upd, get_upd)

    {get, get_upd, upd}
  end

  #

  defp prepare(req, state, leader) do
    # 1. Divide keys
    {get, get_upd, upd} = sets(req, state)

    # 2. Spawning workers
    state = Enum.reduce(get_upd, state, &spawn_worker(&2, &1))
    {values, workers} = state

    #

    get_upd = Map.take(workers, get_upd)

    #

    workers = Map.take(workers, get)
    values = Map.take(values, get)

    {known, get} =
      if req.! == :now do
        {Map.merge(values(workers), values), %{}}
      else
        {values, workers}
      end

    # 3. Prepairing workers

    # workers with keys from {get} are asked
    # to share their values
    for {key, worker} <- get do
      # `tiny: true` is used to prevent worker
      # to spawn `Task` to handle this request
      send(worker, %{
        act: :get,
        fun: &share(key, &1, &2),
        from: leader,
        tiny: true,
        !: req.!
      })
    end

    t = req.timeout

    # workers with keys from {get_upd} are asked
    # to share their values and wait for a new ones
    for {key, worker} <- get_upd do
      send(worker, %{
        act: :get_upd,
        fun: &share_accept(key, &1, &2, from: leader, timeout: t),
        from: leader,
        !: {:avg, +1}
      })
    end

    #               —┐        ┌—
    # map with pids  |        |  map with pids for keys
    # for keys whose |        |     that are planned to
    # values will    |        | update and whose values
    # only be        |        |       will be collected
    # collected     —┤        ├—
    #                |        |      ┌ keys that are only
    #                ┆        ┆      ┆  planned to update
    #                ↓        ↓      ↓
    {state, known, {get, get_upd, to_list(upd)}}
    #        (M)   ↑ (M)   (M)  ↑     (L)
    #              ┆            ┆
    #              ┆  callback  ┆
    #              |  argument  |
    #              ├————————————┤
    #              ┆  workers   ┊
    #              ├————————————┘
    #              ↑                          ↑
    #              ┆         disjoint         ┆
    #              └——————————————————————————┘
  end

  ##
  ## COLLECT
  ##

  defp collect(known, []), do: known

  defp collect(known, keys) do
    receive do
      {k, {value}} ->
        keys = List.delete(keys, k)

        known
        |> Map.put(k, value)
        |> collect(keys)

      {k, nil} ->
        keys = List.delete(keys, k)

        collect(known, keys)

      msg ->
        Logger.warn("""
        Leader process #{inspect(self())} got unexpected message while
        collecting values.

        Message: #{inspect(msg)}.
        """)
    end
  end

  ##
  ## FINALIZE
  ##

  defp commit(req, msg) when is_list(msg) do
    commit(req, Map.new(msg))
  end

  defp commit(_r, %{get: [], upd: %{}}), do: :ok

  defp commit(req, msg) do
    commit = struct(Commit, msg)

    if req.from do
      keys = GenServer.call(req.server, commit, :infinity)

      drop = msg[:drop] || []
      upd = msg[:upd] || %{}

      collect(%{}, (drop ++ Map.keys(upd)) -- keys)
    else
      GenServer.cast(req.server, commit)
    end

    :ok
  end

  # {ret, map with values}
  defp finalize(req, {ret, values}, _k, {get_upd, upd})
       when is_map(values) do
    #
    # dealing with workers waiting for a new value
    # (get_upd map with keys from {req.get ∩ req.upd})

    ballast = Map.keys(get_upd) -- Map.keys(values)

    for {key, worker} <- get_upd do
      if key in ballast do
        send(worker, :drop)
      else
        new_value = values[key]
        send(worker, {new_value})
      end
    end

    #
    new_values = Map.drop(values, Map.keys(get_upd))
    ballast = upd -- Map.keys(values)

    commit(req, drop: ballast, upd: new_values)
    reply(req.from, ret)
  end

  # {ret} = {ret, :id}
  defp finalize(req, {ret}, known, sets) do
    finalize(req, {ret, :id}, known, sets)
  end

  defp finalize(req, {ret, :id}, _k, {get_upd, _upd}) do
    # let go of workers
    for {_key, worker} <- get_upd do
      send(worker, :id)
    end

    reply(req.from, ret)
  end

  # {ret, :drop}
  defp finalize(req, {ret, :drop}, _k, {get_upd, upd}) do
    for {_key, worker} <- get_upd do
      send(worker, :drop)
    end

    commit(req, drop: upd)
    reply(req.from, ret)
  end

  # wrong length of the new values list
  defp finalize(_r, {ret, new_values}, _k, {get_upd, []})
       when map_size(get_upd) != length(new_values) do
    #
    m = map_size(get_upd)
    n = length(new_values)

    raise CallbackError, got: {ret, new_values}, len: n, expected: m
  end

  # {ret, new [value]s}
  defp finalize(req, {ret, new_values}, _k, {get_upd, upd}) do
    new_values =
      req.upd
      |> Enum.zip(new_values)
      |> Map.new()

    for {key, worker} <- get_upd do
      send(worker, {new_values[key]})
    end

    commit(req, upd: Map.take(new_values, upd))
    reply(req.from, ret)
  end

  # :id — change nothing
  # :id = [:id, :id, :id, …]
  defp finalize(req, :id, known, {get_upd, []}) do
    ids = List.duplicate(:id, map_size(get_upd))
    finalize(req, ids, known, {get_upd, []})
  end

  # :pop — return list with values, make drop
  # :pop = [:pop, :pop, …]
  defp finalize(req, :pop, known, {get_upd, []}) do
    pops = List.duplicate(:pop, map_size(get_upd))
    finalize(req, pops, known, {get_upd, []})
  end

  # wrong length of the actions list
  defp finalize(_r, acts, _k, {get_upd, []})
       when map_size(get_upd) != length(acts) do
    #
    m = map_size(get_upd)
    n = length(acts)

    raise CallbackError, got: acts, len: n, expected: m
  end

  #    ┌————————————┐
  #    ┆  explicit  ┆
  #    ↓            ↓
  # [{ret} | {ret, new value} | :id | :pop]
  defp finalize(req, acts, known, {get_upd, []}) when is_list(acts) do
    #
    # checking for malformed actions

    for {a, i} <- Enum.with_index(acts, 1) do
      unless match?({_}, a) || match?({_, _}, a) || a in [:id, :pop] do
        raise CallbackError, got: acts, pos: i, item: a
      end
    end

    #
    # making keyword [key → action to perform]

    keys = Map.keys(get_upd)
    acts = Enum.zip(req.upd, acts)

    #
    # dealing with workers waiting for a new value
    # (get_upd map with keys from req.get ∩ req.upd)

    known =
      for {key, worker} <- get_upd do
        case acts[key] do
          {ret, new_value} ->
            send(worker, {new_value})
            {key, ret}

          {ret} ->
            send(worker, :id)
            {key, ret}

          :id ->
            send(worker, :id)
            nil

          :pop ->
            send(worker, :drop)
            nil
        end
      end
      |> Enum.filter(& &1)
      |> Enum.into(known)

    ret = Enum.map(keys, &Map.get(known, &1, req.initial))
    reply(req.from, ret)
  end

  # dealing with a malformed response
  defp finalize(_req, malformed, _known, _sets) do
    raise CallbackError, got: malformed, multi_key?: true
  end

  ##
  ## HANDLE
  ##

  def handle(req, state) do
    leader = spawn_leader(%{req | server: self()})

    {state, known, sets} = prepare(req, state, leader)

    send(leader, {known, sets})

    {:noreply, state}
  end
end

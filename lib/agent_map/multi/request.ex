defmodule AgentMap.Multi.Req do
  @moduledoc false

  #

  @type key :: AgentMap.key()
  @type value :: AgentMap.value()
  @type cb_m :: AgentMap.cb_m()

  @typedoc """
  This struct is sent by `Multi.get_and_update/4` and `take/3`.

  Fields:

    * initial: value for missing keys;
    * server: pid;
    * from: replying to;
    * !: priority to be used when collecting values;
    * get: keys whose values form a callback arg;
    * upd: keys whose values are updated;
    * fun: callback.
  """
  @type t ::
          %__MODULE__{
            get: [key],
            upd: [key],
            fun: cb_m,
            initial: term,
            server: pid,
            from: GenServer.from(),
            !: non_neg_integer | :now
          }

  defstruct [
    :fun,
    :initial,
    :server,
    :from,
    get: [],
    upd: %{},
    !: :now
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
  ##    to be dropped (`:drop`) and a keyword with update data (`:upd`). Also,
  ##    request is sent to collected unknown values.

  alias AgentMap.{CallbackError, Req, Multi, Server, Worker, Req.Commit}

  # !
  import Kernel, except: [apply: 2]
  import Server, only: [apply: 2, spawn_worker: 2, extract_state: 1]

  import Worker, only: [values: 1]

  import Req, only: [reply: 2]

  import MapSet, only: [intersection: 2, difference: 2, to_list: 1]
  import Enum, only: [into: 2, uniq: 1, zip: 2, reduce: 3, filter: 2, map: 2, split_with: 2]
  import List, only: [delete: 2]

  ##
  ## CALLBACKS
  ##

  defp share(key, value, exist?) do
    {key, if(exist?, do: {value})}
  end

  defp share_accept(key, value, exist?, from: pid) do
    send(pid, share(key, value, exist?))

    receive do
      :drop ->
        :pop

      :id ->
        :id

      {new_value} ->
        {:_set, new_value}
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

          arg =
            if req.get == :all do
              known
            else
              init = req.initial
              Enum.map(req.get, &Map.get(known, &1, init))
            end

          #          IO.inspect(req, label: :req)

          ret = apply(req.fun, [arg])

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
    {get, get_upd, upd} = sets(req, state) |> IO.inspect()

    # 2. Spawning workers
    state = reduce(get_upd, state, &spawn_worker(&2, &1))
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

    # workers with keys from {get_upd} are asked
    # to share their values and wait for a new ones
    for {key, worker} <- get_upd do
      send(worker, %{
        act: :upd,
        fun: &share_accept(key, &1, &2, from: leader),
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
        keys = delete(keys, k)

        known
        |> Map.put(k, value)
        |> collect(keys)

      {k, nil} ->
        keys = delete(keys, k)

        collect(known, keys)
    end
  end

  ##
  ## FINALIZE
  ##

  # {ret, map with values}
  defp finalize(req, {ret, values}, _k, {get_upd, upd}) when is_map(values) do
    ballast = (Map.keys(get_upd) ++ upd) -- Map.keys(values)

    #
    # dealing with workers waiting for a new value
    # (get_upd map with keys from req.get ∩ req.upd)

    for {key, worker} <- get_upd do
      action =
        if key in ballast do
          :pop
        else
          {values[key]}
        end

      send(worker, action)
    end

    #

    new_values = Map.drop(values, Map.keys(get_upd))

    GenServer.cast(req.server, %Commit{
      drop: ballast,
      upd: new_values
    })

    ret
  end

  # {ret}
  defp finalize(req, {ret}, known, sets) do
    finalize(req, {ret, :id}, known, sets)
  end

  defp finalize(req, {ret, :id}, _k, {get_upd, _}) do
    for {_key, worker} <- get_upd do
      send(worker, :id)
    end

    ret
  end

  defp finalize(req, {ret, :drop}, _k, {get_upd, upd}) do
    for {_key, worker} <- get_upd do
      send(worker, :drop)
    end

    GenServer.cast(req.server, %Commit{drop: upd})

    ret
  end

  # wrong length of the new values list
  defp finalize(%{upd: keys}, {ret, new_values}, _k, _sets)
       when length(keys) != length(new_values) do
    #
    m = length(keys)
    n = length(new_values)

    raise CallbackError, got: {ret, new_values}, len: n, expected: m
  end

  # {ret, new values}
  defp finalize(req, {ret, new_values}, _k, {get_upd, upd}) do
    new_values = zip(req.upd, new_values)

    for {key, worker} <- get_upd do
      send(worker, {new_values[key]})
    end

    new_values =
      new_values
      |> Keyword.take(upd)
      |> Map.new()

    GenServer.cast(req.server, %Commit{upd: new_values})

    ret
  end

  # :id | :pop
  defp finalize(req, act, known, sets) when act in [:id, :pop] do
    acts = List.duplicate(act, length(req.upd))

    finalize(req, acts, known, sets)
  end

  # wrong length of the actions list
  defp finalize(%{upd: keys}, acts, _k, _s) when length(keys) != length(acts) do
    m = length(keys)
    n = length(acts)

    raise CallbackError, got: acts, len: n, expected: m
  end

  #    ┌————————————┐
  #    ┆  explicit  ┆
  #    ↓            ↓
  # [{ret} | {ret, new value} | :id | :pop]
  defp finalize(req, acts, known, {get_upd, upd}) when is_list(acts) do
    explicit? = &(is_tuple(&1) && tuple_size(&1) in [1, 2])

    #
    # checking for malformed actions

    for {act, i} <- Enum.with_index(acts, 1) do
      unless explicit?.(act) || act in [:id, :pop] do
        raise CallbackError, got: acts, pos: i, item: act
      end
    end

    #
    # making keyword [key → action to perform]

    acts = zip(req.upd, acts)

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
      |> filter(& &1)
      |> into(known)

    # update "only update" keys (req.upd ∖ req.get)

    {e_acts, others} =
      acts
      |> Keyword.take(upd)
      |> split_with(&explicit?.(elem(&1, 1)))

    new_values =
      for {key, {_ret, new_v}} <- e_acts, into: %{} do
        {key, new_v}
      end

    ballast = for {key, :pop} <- e_acts, do: key

    commit = %Commit{
      drop: ballast,
      upd: new_values
    }

    if req.from do
      # TODO: use 2 Task's and GenServer.call
      GenServer.cast(req.server, commit)

      # for explicit actions:

      known =
        for {key, act} <- e_acts, into: known do
          #            ⭩ {ret} | {ret, new value}
          {key, elem(act, 0)}
        end

      # for others:

      keys = Keyword.keys(others)

      # # ?
      # priority = (req.! == :now && :now) || {:avg, +1}

      known =
        req.server
        |> GenServer.call(%Multi.Req{
          get: keys,
          fun: &Enum.zip(keys, &1),
          initial: req.initial,
          !: req.!
        })
        |> into(known)

      ret = map(req.upd, &Map.get(known, &1, req.initial))

      reply(req.from, ret)
    else
      GenServer.cast(req.server, commit)
    end
  end

  # dealing with a malformed response
  defp finalize(_req, malformed, _known, _sets) do
    raise CallbackError, got: malformed, multi_key?: true
  end

  ##
  ## HANDLE
  ##

  def handle(req, state) do
    req = %{req | server: self()}

    pid = spawn_leader(req)

    {state, known, sets} = prepare(req, state, pid)

    send(pid, {known, sets})

    {:noreply, state}
  end
end

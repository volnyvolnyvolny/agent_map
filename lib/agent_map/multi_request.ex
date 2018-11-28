defmodule AgentMap.Multi.Req do
  @moduledoc false

  ##
  ## *server*
  ##
  ## *. ↳ handle(req, state)
  ##
  ##    Catches a request.
  ##
  ##    1. Starts a *process* that is responsible for execution.
  ##
  ##    2. ↳ prepare(req, state)
  ##
  ##       Ensures that a worker is spawned for each key in `req.get ∩ req.upd`.
  ##       For keys in:
  ##
  ##       * `req.get ∖ req.upd` fetches values or asks workers to share them;
  ##       * `req.get ∩ req.upd` asks workers to "share their values and wait
  ##         for a further instructions".
  ##
  ##       Returns:
  ##
  ##                                               ┌————————————————————┐
  ##                                               ┊      (req.upd)     ┊
  ##                                               ↓      updating      ↓
  ##                                    ┌————————————————————┐
  ##                                    ↓       workers      ↓
  ##                                               ╔════════════════════╗
  ##              ┌─────────┬ ┌───────┬ ┌──────────╫─────────┐   (L)    ║
  ##              │  state  │ │ known │ │ only_get ║ get_upd │ only_upd ║
  ##              │ ({M,M}) │ │  (M)  │ │    (M)   ╚═════════╪══════════╝
  ##              └─────────┴ └───────┴ └────────────────────┘
  ##                          ↑      callback argument       ↑
  ##                          ┊          (req.get)           ┊
  ##                          └——————————————————————————————┘
  ##

  ## *process*
  ##
  ## 1. ↳ collect(known, keys)
  ##
  ##    Collects data shared by workers and adds it to the `known`.
  ##
  ## 2. Callback (`req.fun`) is invoked. It can return:
  ##
  ##    * `{ret, [new value] | :drop | :id}` — an *explicitly* given returned
  ##      value (`ret`) and actions to be taken for every key in `req.upd`;
  ##
  ##    * `[{ret} | {ret, new value} | :pop | :id]` — a composed returned value
  ##      (`[ret | value]`) and individual actions to be taken;
  ##
  ##    * sugar: `{ret} ≅ {ret, :id}`, `:pop ≅ [:pop, …]`, `:id ≅ [:id, …]`.
  ##   └———————————————————┬———————————————————————————————————————————————————┘
  ##                       ⮟
  ## 3. ↳ finalize(req, result, known, {workers (get_upd), only_upd (upd)})
  ##
  ##    Commits changes for all values. Replies.
  ##
  ##    At the moment, `req.get ∩ req.upd` workers are still waiting for
  ##    instructions to resume. From the previos steps we already `know` their
  ##    values and so we have to collect only values for keys in `req.upd ∖
  ##    req.get`.
  ##
  ##    A special `Multi.Req` is send to *server*. It contains keys needs to be
  ##    collected (`:get` field), to be dropped (`:drop`) and a keyword with
  ##    update data (`:upd`).

  alias AgentMap.{CallbackError, Req, Multi, Server}

  import Req, only: [reply: 2]
  import Server, only: [spawn_worker: 2, to_map: 1, extract_state: 1]
  import MapSet, only: [intersection: 2, difference: 2, to_list: 1]
  import Map, only: [put: 3, take: 2]

  import Enum, only: [into: 2, uniq: 1, zip: 2, reduce: 3, filter: 2, map: 2, split_with: 2]

  import List, only: [delete: 2]

  #

  defstruct [
    :fun,
    :initial,
    :server,
    :from,
    get: [],
    upd: %{},
    drop: [],
    !: :now
  ]

  @typedoc """
  This struct is sent by `Multi.get_and_update/4` and `take/3`.

  Fields:

  * initial: value for missing keys;
  * server: pid;
  * from: replying to;
  * !: priority to be used when collecting values.

  * get: keys whose values form a callback arg;
  * upd: keys whose values are updated in a callback;
  * fun: callback;

  or:

  * get: keys whose values are returned;
  * upd: a map with a new values;
  * drop: keys that will be dropped.
  """

  @type key :: AgentMap.key()
  @type value :: AgentMap.value()
  @type cb_m :: AgentMap.cb_m()

  @type t ::
          %__MODULE__{
            get: [key],
            upd: [key] | %{required(key) => value},
            drop: [],
            fun: cb_m,
            initial: term,
            server: pid,
            from: GenServer.from(),
            !: non_neg_integer | :now
          }
          | %__MODULE__{
              get: [key],
              upd: %{required(key) => value},
              drop: [key],
              fun: nil,
              initial: nil,
              server: nil,
              from: pid,
              !: {:avg, +1} | :now
            }

  #

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

  # first, we divide keys on three disjoint sets
  defp sets(req) do
    get = MapSet.new(req.get)
    upd = MapSet.new(req.upd)

    only_get = difference(get, upd)
    only_upd = difference(upd, get)

    get_upd = intersection(get, upd)

    {only_get, get_upd, only_upd}
  end

  #

  defp prepare(req, state, pid) do
    {only_get, get_upd, only_upd} = sets(req)

    #

    state = reduce(get_upd, state, &spawn_worker(&2, &1))
    {map, workers} = state

    get_upd = Map.take(workers, get_upd)
    workers = Map.take(workers, only_get)

    map = take(map, only_get)

    {known, only_get} =
      if req.! == :now do
        {to_map({map, workers}), %{}}
      else
        {map, workers}
      end

    # prepairing workers

    for {key, worker} <- only_get do
      req = %{
        act: :get,
        fun: &share(key, &1, &2),
        from: pid,
        tiny: true,
        !: req.!
      }

      send(worker, req)
    end

    for {key, worker} <- get_upd do
      req = %{
        act: :upd,
        fun: &share_accept(key, &1, &2, from: pid),
        from: pid,
        !: {:avg, +1}
      }

      send(worker, req)
    end

    #                  —┐        ┌—
    # map with pids for |        |  map with pids for keys
    # keys whose values |        |     that are planned to
    # will only be      |        | update and whose values
    # collected         |        |       will be collected
    #                  —┤        ├—
    #                   |        |      ┌ keys that are only
    #                   ┆        ┆      ┆  planned to update
    #                   ↓        ↓      ↓
    {state, known, {only_get, get_upd, only_upd |> to_list()}}
    #        (M)   ↑   (M)      (M)  ↑    (L)
    #              ┆     callback    ┆
    #              |     argument    |
    #              ├—————————————————┤
    #              ┆     workers     ┊
    #              ├—————————————————┘
    #              ↑                                        ↑
    #              ┆              sets of keys              ┆
    #              └————————————————————————————————————————┘
  end

  #

  defp collect(known, []), do: known

  defp collect(known, keys) do
    receive do
      {key, {value}} ->
        known
        |> put(key, value)
        |> collect(delete(keys, key))

      {key, nil} ->
        collect(known, delete(keys, key))
    end
  end

  #

  # {ret}
  defp finalize(req, {ret}, known, sets) do
    finalize(req, {ret, :id}, known, sets)
  end

  # {ret, :id | :drop}
  defp finalize(req, {ret, act}, _, {workers, _}) when act in [:id, :drop] do
    for {_key, pid} <- workers do
      send(pid, act)
    end

    if act == :drop do
      r = %Multi.Req{drop: req.upd}
      GenServer.cast(req.server, r)
    end

    ret
  end

  # malformed {ret, list} (because of list length)
  defp finalize(%{upd: keys}, {_ret, list} = got, _, {_, _})
       when length(keys) != length(list) do
    #
    m = length(keys)
    n = length(list)

    raise CallbackError, got: got, len: n, expected: m
  end

  # {ret, [new values]}
  defp finalize(req, {ret, new_values}, _, {workers, only_upd}) do
    new_values = zip(req.upd, new_values)

    for {key, pid} <- workers do
      send(pid, {new_values[key]})
    end

    new_values =
      new_values
      |> Keyword.take(only_upd)
      |> Map.new()

    r = %Multi.Req{upd: new_values}
    GenServer.cast(req.server, r)

    ret
  end

  # :id | :pop
  defp finalize(req, act, known, sets) when act in [:id, :pop] do
    n = length(req.upd)
    acts = List.duplicate(act, n)

    finalize(req, acts, known, sets)
  end

  # malformed [act] (because of length)
  defp finalize(%{upd: keys}, acts, _, _) when length(keys) != length(acts) do
    m = length(keys)
    n = length(acts)

    raise CallbackError, got: acts, len: n, expected: m
  end

  #    ┌————————————┐
  #    ┆  explicit  ┆
  #    ↓            ↓
  # [{ret} | {ret, new value} | :id | :pop]
  defp finalize(req, acts, known, {workers, only_upd}) do
    explicit? = &(is_tuple(&1) && tuple_size(&1) in [1, 2])

    # checking for malformed actions:
    for {act, i} <- Enum.with_index(acts, 1) do
      unless explicit?.(act) || act in [:id, :pop] do
        raise CallbackError, got: acts, pos: i, item: act
      end
    end

    acts = zip(req.upd, acts)

    known =
      for {key, pid} <- workers, into: %{} do
        case acts[key] do
          {ret, new_value} ->
            send(pid, {new_value})
            {key, ret}

          {ret} ->
            send(pid, :id)
            {key, ret}

          :id ->
            send(pid, :id)
            nil

          :pop ->
            send(pid, :drop)
            nil
        end
      end
      |> filter(& &1)
      |> into(known)

    # update "only update" keys (req.upd ∖ req.get)

    {e_acts, others} =
      acts
      |> Keyword.take(only_upd)
      |> split_with(&explicit?.(elem(&1, 1)))

    new_values =
      for {key, {_ret, new_v}} <- e_acts, into: %{} do
        {key, new_v}
      end

    ballast = for {key, :pop} <- e_acts, do: key

    if req.from do
      # for explicit actions:

      known =
        for {key, act} <- e_acts, into: known do
          #            ⭩ {ret} | {ret, new value}
          {key, elem(act, 0)}
        end

      # for others:

      keys = Keyword.keys(others)
      priority = (req.! == :now && :now) || {:avg, +1}

      r = %Multi.Req{
        get: keys,
        drop: ballast,
        upd: new_values,
        !: priority
      }

      known =
        req.server
        |> GenServer.call(r)
        |> into(known)

      # reply
      map(req.upd, &Map.get(known, &1, req.initial))
    else
      r = %Multi.Req{
        drop: ballast,
        upd: new_values
      }

      GenServer.cast(req.server, r)
    end
  end

  # any other malformed
  defp finalize(_req, malformed, _known, _sets) do
    raise CallbackError, got: malformed, multi_key?: true
  end

  ##
  ##
  ##

  # %Multi.Req{get: …, upd: …, drop: …}
  def handle(%{fun: nil} = req, state) do
    #
    # GET:

    {:ok, pid} =
      Task.start_link(fn ->
        receive do
          {:collect, known, keys} ->
            reply(req.from, collect(known, keys))
        end
      end)

    get = %Req{Map.from_struct(req) | act: :get, tiny: true, from: pid}

    {state, known, keys} =
      reduce(uniq(req.get), {state, %{}, []}, fn k, {state, known, keys} ->
        req = %{get | key: k, fun: &share(k, &1, &2)}

        case Req.handle(req, state) do
          {:noreply, state} ->
            {state, known, [k | keys]}

          {:reply, {key, {:v, value}}, state} ->
            {state, Map.put(known, key, value), keys}

          {:reply, {_, nil}, state} ->
            {state, known, keys}
        end
      end)

    send(pid, {:collect, known, keys})

    # DROP:

    pop = %Req{act: :upd, fun: fn _ -> :pop end, tiny: true, !: {:avg, +1}}

    state =
      reduce(req.drop, state, fn k, state ->
        %{pop | key: k}
        |> Req.handle(state)
        |> extract_state()
      end)

    # UPDATE:

    state =
      reduce(req.upd, state, fn {k, new_value}, state ->
        %{pop | key: k, fun: fn _ -> new_value end}
        |> Req.handle(state)
        |> extract_state()
      end)

    {:noreply, state}
  end

  # main:
  def handle(req, state) do
    req = %{req | server: self()}

    {:ok, pid} =
      Task.start_link(fn ->
        receive do
          {known, {only_get, get_upd, only_upd}} ->
            keys = Map.keys(only_get) ++ Map.keys(get_upd)
            known = collect(known, keys)
            init = req.initial

            arg = map(req.get, &Map.get(known, &1, init))

            ret =
              finalize(
                req,
                apply(req.fun, arg),
                known,
                {get_upd, only_upd}
              )

            reply(req.from, ret)
        end
      end)

    {state, known, sets} = prepare(req, state, pid)

    send(pid, {known, sets})

    {:noreply, state}
  end
end

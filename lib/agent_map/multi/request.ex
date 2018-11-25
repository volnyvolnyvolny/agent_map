defmodule AgentMap.Multi.Req do
  @moduledoc false

  ##
  ## *server*
  ##
  ## *. ↳ handle(req, state)
  ##
  ##    Catches a request. Here `state` is a map with each key corresponds to
  ##    either a `value` or a pid of the `worker` process.
  ##
  ##    1. Starts a *process* that is responsible for execution.
  ##
  ##    2. ↳ prepare(req, state)
  ##
  ##       Ensures that a worker is spawned for each key in `req.get ∩ req.upd`.
  ##       For keys in:
  ##
  ##       * `req.get ∖ req.upd` asks workers to share their values or fetch
  ##         them;
  ##       * `req.get ∩ req.upd` asks workers to "share their values and wait
  ##         for a further instructions".
  ##
  ##       Returns:
  ##
  ##                                          ┌———————————————┐
  ##                                          ┊     updating  ┊
  ##                                          ↓    (req.upd)  ↓
  ##                                    ┌———————————————┐
  ##                                    ↓  (M) workers  ↓
  ##                                          ╔═══════════════╗
  ##                ┌───────┬ ┌───────┬ ┌─────╫─────────┐ (L) ║
  ##                │ state │ │ known │ │ get ║ get_upd │ upd ║
  ##                │  (M)  │ │  (M)  │ │     ╚═════════╪═════╝
  ##                └───────┴ └───────┴ └───────────────┘
  ##                          ↑    callback argument    ↑
  ##                          ┊        (req.get)        ┊
  ##                          └—————————————————————————┘

  ## *process*:
  ##
  ## 1. ↳ collect(keys)
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
  ##  └————————————————————┬———————————————————————————————————————————————————┘
  ##                       ⮟
  ## 3. ↳ finalize(req, result, known, {workers (get_upd), only_upd (upd)})
  ##
  ##    Commits changes for all values. Replies.
  ##
  ##    At the moment, `get_upd` workers are still waiting for instructions to
  ##    resume. From the previos steps we already `know` their values and so we
  ##    have to collect only values for keys in `req.upd ∖ req.get`.
  ##
  ##    A special `Multi.Req` is send to *server*. It contains keys needs to be
  ##    collected (`:get` field), to be dropped (`:drop`) and a keyword with
  ##    update data (`:upd`).

  alias AgentMap.{CallbackError, Server.State, Worker, Req, Multi}

  import Req, only: [reply: 2]
  import State, only: [separate: 2, take: 2, spawn_worker: 2]
  import MapSet, only: [intersection: 2, difference: 2, to_list: 1]
  import Map, only: [put: 3, keys: 1, merge: 2, get: 3]

  import Enum,
    only: [into: 2, zip: 2, unzip: 1, uniq: 1, reduce: 3, map: 2, split_with: 2, filter: 2]

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
              initial: term,
              server: nil,
              from: pid,
              !: {:avg, +1} | :now
            }

  #

  defp share(key, value, exist?) do
    {key, if(exist?, do: {:v, value})}
  end

  #

  defp prepare(req, state, pid) do
    # collect
    get = MapSet.new(req.get)
    # update
    upd = MapSet.new(req.upd)

    # collect & update
    get_upd = intersection(get, upd)

    state = reduce(get_upd, state, &spawn_worker(&2, &1))

    get_upd = Map.take(state, get_upd)

    only_get = difference(get, upd)

    {known, get} =
      if req.! == :now do
        {take(state, only_get), %{}}
      else
        separate(state, only_get)
      end

    only_upd = difference(upd, get)

    #

    share_accept = fn key, value, exist? ->
      send(pid, share(key, value, exist?))

      receive do
        :drop ->
          :pop

        :id ->
          :id

        {:v, new_value} ->
          {:_set, new_value}
      end
    end

    for {key, worker} <- get do
      send(worker, %{act: :get, fun: &share(key, &1, &2), from: pid, !: req.!})
    end

    for {key, worker} <- get_upd do
      send(worker, %{act: :update, fun: &share_accept(key, &1, &2), !: {:avg, +1}})
    end

    #               —┐        ┌—
    # map with pids  |        |    map with pids for keys
    # for keys whose |        |       that are planned to
    # values will    |        |   update and whose values
    # only be        |        |         will be collected
    # collected      |        ├—
    #               —┤        |      ┌ keys that are only
    #                ┆        ┆      ┆  planned to update
    #                ↓        ↓      ↓
    {state, known, {get, get_upd, only_upd |> to_list()}}
    #        (M)  ↑              ↑   (L)
    #             ┆   callback   ┆
    #             |   argument   |
    #             ├——————————————┤
    #             ┆  (M) workers ┊
    #             ├——————————————┘
    #             ↑                                     ↑
    #             ┆            sets of keys             ┆
    #             └—————————————————————————————————————┘
  end

  #

  defp collect(keys), do: collect(%{}, uniq(keys))

  defp collect(known, []), do: known

  defp collect(known, keys) do
    receive do
      {key, {:v, value}} ->
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
      send(pid, :id)
    end

    if act == :drop do
      r = %Multi.Req{drop: req.upd}
      GenServer.cast(req.server, r)
    end

    ret
  end

  defp finalize(%{upd: keys}, {_ret, list} = got, {_, _})
       when length(keys) != length(list) do
    #
    m = length(keys)
    n = length(list)

    raise CallbackError, got: got, len: n, expected: m
  end

  # {ret, [new values]}
  defp finalize(req, {ret, new_values}, _({workers, only_upd})) do
    new_values = zip(req.upd, new_values)

    for {key, pid} <- workers do
      send(pid, {:v, new_values[key]})
    end

    only_upd = Keyword.take(new_values, only_upd)

    r = %Multi.Req{upd: only_upd |> into(%{})}
    GenServer.cast(req.server, r)

    ret
  end

  # :id | :pop
  defp finalize(req, act, known, sets) when act in [:id, :pop] do
    n = length(req.upd)
    acts = List.duplicate(act, n)

    finalize(req, acts, known, sets)
  end

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
        raise CallbackError, got: act, pos: i, item: act
      end
    end

    acts = zip(req.upd, acts)

    known =
      for {key, pid} <- workers, into: %{} do
        case acts[key] do
          {{ret, new_value}, _} ->
            send(pid, {:v, new_value})
            {key, ret}

          {{ret}, _} ->
            send(pid, :id)
            {key, ret}

          {:id, _} ->
            send(pid, :id)
            {key, Map.get(known, key, req.initial)}

          {:pop, _} ->
            send(pid, :drop)
            {key, Map.get(known, key, req.initial)}
        end
      end

    if req.from do
      {e_acts, others} = split_with(acts, &explicit?.(elem(&1, 1)))

      # for explicit actions:

      known =
        for {key, act} <- e_acts, into: known do
          #            ⭩ {ret} | {ret, new value}
          {key, elem(act, 0)}
        end

      new_values =
        for {key, {_ret, new_v}} <- e_acts, into: %{} do
          {key, new_v}
        end

      # for others:

      keys = Keyword.keys(others)

      r = %Multi.Req{
        get: keys,
        drop: for({k, :pop} <- others, do: k),
        upd: new_values,
        initial: req.initial,
        !: (req.! == :now && :now) || {:avg, +1}
      }

      known =
        req.server
        |> GenServer.call(r)
        |> zip(keys)
        |> map(fn {v, k} -> {k, v} end)
        |> into(known)

      map(req.upd, &known[&1])
    else
      r = %Multi.Req{
        drop: for({k, :pop} <- acts, do: k),
        upd: for({k, {_ret, new_v}} <- acts, do: {k, new_v})
      }

      GenServer.cast(req.server, r)
    end
  end

  def finalize(_req, malformed, _known, _sets) do
    raise CallbackError, got: malformed, multi_key?: true
  end

  ##
  ##
  ##

  # %Multi.Req{get: …, upd: …, drop: …}
  def handle(%{fun: nil} = req, state) do
    {:ok, pid} =
      Task.start_link(fn ->
        receive do
          {:collect, known, keys} ->
            known = collect(known, keys)
            ret = map(req.get, &Map.get(known, &1, req.initial))

            reply(req.from, ret)
        end
      end)

    # GET:

    get = %{Map.from_struct(req) | act: :get, tiny: true, from: pid}

    {state, known, keys} =
      reduce(req.get, {state, %{}, []}, fn k, {state, known, keys} ->
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

    pop = %{act: :update, fun: fn _ -> :pop end, tiny: true, !: {:avg, +1}}

    state =
      reduce(req.drop, state, fn k, state ->
        %{pop | key: k}
        |> Req.handle(state)
        |> State.extract()
      end)

    # UPDATE:

    state =
      reduce(req.upd, state, fn {k, new_value}, state ->
        %{pop | key: k, fun: fn _ -> new_value end}
        |> Req.handle(state)
        |> State.extract()
      end)

    {:noreply, state}
  end

  # main:
  def handle(req, state) do
    req = %{req | server: self()}

    {:ok, pid} =
      Task.start_link(fn ->
        receive do
          {known, get, get_upd, upd} ->
            known = collect(known, keys(get) ++ keys(get_upd))

            arg = map(req.get, &Map.get(known, &1, req.initial))

            args =
              if is_function(req.fun, 2) do
                exist? = map(req.get, &Map.has_key?(known, &1))
                [arg, exist?]
              else
                [arg]
              end

            ret =
              finalize(
                req,
                apply(req.fun, args),
                known,
                {get_upd, upd}
              )

            reply(req.from, ret)
        end
      end)

    {state, data} = prepare(req, state, pid)

    send(pid, data)

    {:noreply, state}
  end
end

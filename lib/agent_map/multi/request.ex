defmodule AgentMap.Multi.Req do
  @moduledoc false

  # Logic behind `Multi.get_and_update/4` that is used in all `Multi.*` calls
  # and `take/3`.
  #
  # How it works:
  #
  # + *server*:
  #
  #   1. ↳ `handle(req, state)`
  #
  #      Catches a request. Here `state` is a map with each key corresponds to
  #      either a `value` or a pid of the `worker` process.
  #
  #   2. ↳ `prepare(req, state)`
  #
  #      Ensures that workers are spawned for keys in `req.get ∩ req.upd` set
  #      and returns:
  #
  #      0. `state` with pids of the workers that were spawned;
  #      1. map (`known`) with values that were explicitly stored in `state`;
  #      2. a three disjoint sets of keys, holded in two maps (M) and a list (L).
  #
  #
  #                                    ┌———————————————┐
  #                                    ┊     updating  ┊
  #                                    ↓    (req.upd)  ↓
  #                              ┌———————————————┐
  #                              ↓  (M) workers  ↓
  #                                    ╔═══════════════╗
  #                      ┌───────┬─────╫─────────┐ (L) ║
  #                      │ known │ get ║ get_upd │ upd ║
  #                      │ (M)   │     ╚═════════╪═════╝
  #                      └───────┴───────────────┘
  #                      ↑  callback argument    ↑
  #                      ┊  (req.get)            ┊
  #                      └———————————————————————┘
  #
  #   3. Starts *process* that is responsible for execution.
  #
  #   4. *Server* stays on hold while *process* sends instructions to each
  #      `worker` involved.
  #
  # + *process*:
  #
  #   1. ↳ `prepare_worker(get, get_upd, priority of request)`
  #
  #      This method:
  #
  #      * asks `get` workers to share their values with the *process*;
  #
  #      * asks `get_and_upd` workers to share their values and wait for a
  #        further instructions.
  #
  #   2. *Server* resumes.
  #
  #   3. ↳ `collect(keys)`
  #
  #      Collecting values shared to *process* by workers (step p. 1). Here
  #      *process* waits until values for all the involved keys are collected.
  #
  #      This may take some time as some of the workers may be too busy. The
  #      downside is that `get_upd` workers who have already shared their values
  #      are stucked, waiting for values from the busy-workers.
  #
  #   4. Collected data is added to the `know` map.
  #
  #   5. Callback (`req.fun`) is invoked. It can return:
  #
  #      * `{ret, [new value] | :drop | :id}` — an *explicitly* given returned
  #        value (`ret`) and actions to be taken for all the keys in `req.upd`;
  #
  #      * `[{ret} | {ret, new value} | :pop | :id]` — a composed returned value
  #        (`[ret | value]`) and the individual actions to be taken;
  #
  #      * sugar: `{ret} ≅ {ret, :id}`, `:pop ≅ [:pop, …]`, `:id ≅ [:id, …]`.
  #    └————————————————————┬———————————————————————————————————————————————————┘
  #                         ⮟
  #   6. ↳ `finalize(req, result, known, {workers (get_upd), upd})`
  #
  #      Now we need to commit changes for all `req.upd` values and to decide
  #      about the returned value.
  #
  #      At the moment, `get_upd` workers are still waiting for instructions to
  #      continue. From the step p. 4 we `know` values holded by thus workers.
  #      And so, in case when `get_upd` holds the same keys as asked in
  #      `req.upd`, the happy end comes — we just need to compose a returned
  #      value or take the explicitly given.
  #
  #      Otherwise, we have to use *server* to collect values and commit changes
  #      for rest of the keys (`req.upd ∖ req.get`). For this purpose we form a
  #      special `Multi.Req`. This request contain keys needs to be returned
  #      (`:get` field), to be dropped (`:drop`), a keyword with keys to be
  #      updated (`:upd`). The same request is used in `values/2` and `drop/3`.
  #
  #   7. Reply result. Pooh!
  #
  #
  # What's possible to improve here?
  #
  # 1. `collect/1` call. See p. 3:
  #
  #        am = AgentMap.new(a: 1, b: 2, c: 3)
  #        sleep(am, :a, 4_000)
  #
  #        # process A
  #        #
  #        Multi.update(am, [:a, :b], fn [a, b] ->
  #          [a + 1, b + a]
  #        end)
  #
  #        # process B (at the same time)
  #        #
  #        Multi.update(am, [:b, :c], fn [b, c] ->
  #          [b + 1, c + 1]
  #        end)
  #        … save the world …
  #
  #    As we see, any activity is paused for the `:a` key, and `:b` is a common
  #    key for both update calls.
  #
  #    Now:
  #
  #    * (B → A) if the update-call from B comes a little earlier, this process
  #      will begin to save the world almost immediatelly [total working time:
  #      `4` sec.];
  #
  #    * (A → B) otherwise, saving the world is delayed for `4` seconds [total
  #      working time: `8` sec.].
  #
  #    In both cases the state of `AgentMap` will be `%{a: 2, b: 4, c: 4}`.
  #
  #    How to optimize performance?
  #
  # 2. I don't like that `prepare/2` and `prepare_workers/3` are executed in a
  #    different processes. This is done so because inside `prepare_workers` we
  #    send callbacks that capture *process* `pid`. It would be nice to prepare
  #    everything in a single *server* call.
  #
  # 3. It would be nice to implement `tiny: true` option for multi-key calls.

  alias AgentMap.{CallbackError, Server.State, Worker, Req, Multi}

  import Req, only: [reply: 2]
  import State, only: [separate: 2, take: 2, spawn_worker: 2]
  import MapSet, only: [intersection: 2, difference: 2, to_list: 1]
  import Map, only: [put: 3, keys: 1, merge: 2, get: 3]
  import Enum, only: [into: 2, zip: 2, unzip: 1, uniq: 1, reduce: 3, map: 2, split_with: 2, filter: 2]
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

  @type key :: AgentMap.key
  @type value :: AgentMap.value
  @type cb_m :: AgentMap.cb_m

  @type t :: %__MODULE__{
    get: [key],
    upd: [key] | %{required(key) => value},
    drop: [],
    fun: cb_m,
    initial: term,
    server: pid,
    from: GenServer.from,
    !: non_neg_integer | :now
  } | %__MODULE__{
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

  # {s. 2}
  defp prepare(%{get: get, upd: upd} = req, state) do
                                      # keys whose values …
    get = MapSet.new(get)             # …form a callback argument
    upd = MapSet.new(upd)             # …are planned to update

    get_upd = intersection(get, upd)  # collect & update

    state =
      reduce(get_upd, state, &spawn_worker(&2, &1))

    get_upd = Map.take(state, get_upd)

    only_get = difference(get, upd)

    {known, get} =
      if req.! == :now do
        {take(state, only_get), %{}}
      else
        separate(state, only_get)
      end

    only_upd = difference(upd, get)

    #               ┈┐        ┌┈
    # map with pids  ┆        ┆    map with pids for keys
    # for keys whose ┆        ┆       that are planned to
    # values will    ┆        ┆   update and whose values
    # only be        ┆        ┆         will be collected
    # collected      ┆        ├┈
    #               ┈┤        ┆      ┌ keys that are only
    #                ┆        ┆      ┆  planned to update
    #                ↓        ↓      ↓
    {state, known, {get, get_upd, only_upd |> to_list()}}
    #         Ⓜ   ┆┆            ┆    Ⓛ                  ┆
    #             ┆┆  callback  ┆                       ┆
    #             ┆┆  argument  ┆                       ┆
    #             ┆├┈┈┈┈┈┈┈┈┈┈┈┈┤                       ┆
    #             ┆┊  Ⓜ workers ┊                       ┆
    #             ┆└┄┄┄┄┄┄┄┄┄┄┄┄┘                       ┆
    #             ┆                                     ┆
    #             ┆         sets of keys, s. 2          ┆
    #             └┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┘
  end

  # p. 1
  defp prepare_workers(get, get_upd, priority) do
    me = self()

    share = fn value, exist? ->
      {key, if exist?, do: {:v, value}}
    end

    share_accept = fn value, exist? ->
      send me, share.(value, exist?)

      receive do
        :drop ->
          :pop

        :id ->
          :id

        {:v, new_value} ->
          {:_set, new_value}
      end
    end

    #

    for {key, worker} <- get do
      send worker, %{act: :get, fun: share, from: me, !: priority}
    end

    for {key, worker} <- get_upd do
      send worker, %{act: :update, fun: share_accept, !: {:avg, +1}}
    end
  end

  #

  # p. 3
  defp collect(keys), do: collect(%{}, uniq(keys))

  defp collect(map, []), do: map

  defp collect(map, keys) do
    receive do
      {key, {:v, value}} ->
        map
        |> put(key, value)
        |> collect(delete(keys, key))

      {key, nil} ->
        collect(map, delete(keys, key))
    end
  end

  #

  # p. 6, when return value is explicitly specified

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
  defp finalize(req, {ret, new_values}, _ {workers, only_upd}) do
    new_values = zip(req.upd, new_values)

    for {key, pid} <- workers do
      send pid, {:v, new_values[key]}
    end

    only_upd =
      Keyword.take(new_values, only_upd)

    r = %Multi.Req{upd: only_upd |> into(%{})}
    GenServer.cast(req.server, r)

    ret
  end

  # p. 6, when return value needs a compose

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

  #    ┌┄┄┄┄┄┄┄┄┄┄┄┄┐
  #    ┆  explicit  ┆
  #    ↓            ↓
  # [{ret} | {ret, new value} | :id | :pop]
  defp finalize(req, acts, known, {workers, only_upd}) do
    explicit? = & is_tuple(&1) && (tuple_size(&1) in [1, 2])

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
            send pid, {:v, new_value}
            {key, ret}

          {{ret}, _} ->
            send pid, :id
            {key, ret}

          {:id, _} ->
            send pid, :id
            {key, Map.get(known, key, req.initial)}

          {:pop, _} ->
            send pid, :drop
            {key, Map.get(known, key, req.initial)}
        end
      end

    if req.from do
      {e_acts, others} =
        split_with(acts, &explicit?.(elem(&1, 1)))

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

      r =
        %Multi.Req{
          get: keys,
          drop: (for {k, :pop} <- others, do: k),
          upd: new_values,
          initial: req.initial,
          !: req.! == :now && :now || {:avg, +1}
        }

      known =
        req.server
        |> GenServer.call(r)
        |> zip(keys)
        |> map(fn {v, k} -> {k, v} end)
        |> into(known)

      map(req.upd, &known[&1])
    else
      r =
        %Multi.Req{
          drop: (for {k, :pop} <- acts, do: k),
          upd: (for {k, {_ret, new_v}} <- acts, do: {k, new_v})
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

  defp req_pop(key, priority, from \\ nil) do
    %{act: :update, key: key, fun: fn _ -> :pop end, tiny: true, !: priority, from: from}
  end

  defp req_put(key, priority, from \\ nil) do
    %{act: :update, key: key, fun: fn _ -> :pop end, tiny: true, !: priority, from: from}
  end

  defp get(req, key, from) do
    %{act: :get, key: k, fun: &{k, &1}, tiny: true, initial: req.initial, from: pid, !: req.priority}
  end

  #

  # p. 6
  def handle(%{fun: nil} = req, state) do
    req = Map.from_struct(req)

    state =
      reduce(req.get, state, fn {k, new_value}, state ->
        %{req | act: :get, key: k, fun: &{k, &1}, tiny: true}
        |> Req.handle(state)
        |> State.extract()
      end)

    r = %{act: :update, tiny: true, !: {:avg, +1}}

    state =
      reduce(req.drop, state, fn k, state ->
        %{r | key: k, fun: fn _ -> :pop end}
        |> Req.handle(state)
        |> State.extract()
      end)

    state =
      reduce(req.upd, state, fn {k, new_value}, state ->
        %{r | key: k, fun: fn _ -> new_value end}
        |> Req.handle(state)
        |> State.extract()
      end)

    {:noreply, state}
  end

  # s. 1
  def handle(req, state) do
    {state, known, sets} = prepare(req, state)  # s. 2

    req = %{req | server: self()}
    ref = make_ref()  # s. 4

    Task.start_link(fn ->
      #
      {get, get_upd, upd} = sets

      prepare_workers(get, get_upd, req.!)  # p. 1
      send(req.server, {ref, :go!})         # p. 2, s. 4

      known =                               # p. 3, 4
        (keys(get) ++ keys(get_upd))
        |> collect()
        |> into(known)

      arg = map(req.get, &Map.get(known, &1, req.initial))  # p. 5

      args =
        if is_function(req.fun, 2) do
          [arg, map]
        else
          [arg]
        end

      result = apply(req.fun, args)
      #                              workers ↘      ↙ keys
      ret = finalize(req, result, known, {get_upd, upd})  # p. 6

      reply(req.from, ret)                                # p. 7
    end)

    # s. 4
    # This prevents workers with an empty queues to die before getting
    # instructions. When server receives `{worker, :die?}` from worker, it first
    # looks if its message queue is empty. And as we send every involved worker
    # an instructions it cannot be empty.

    receive do
      {^ref, :go!} ->
        {:noreply, state}
    end
  end
end

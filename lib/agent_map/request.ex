defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Worker, Server, CallbackError}

  import Server, only: [spawn_worker: 2]
  import Worker, only: [value?: 1, values: 1, inc: 1, to_msg: 1]

  @enforce_keys [:act]

  defstruct [
    :act,
    :initial,
    :from,
    :key,
    :fun,
    :tiny,
    :fun_arity,
    !: :avg
  ]

  #

  def reply(nil, _msg), do: :nothing
  def reply({_p, _ref} = from, msg), do: GenServer.reply(from, msg)
  def reply(from, msg), do: send(from, msg)

  #

  defp collect(key, {values, workers} = _state) do
    case Map.fetch(values, key) do
      {:ok, value} ->
        {value}

      :error ->
        w = workers[key]

        if w, do: value?(w)
    end
  end

  #

  defp args(%{fun_arity: 2}, {value}) do
    [value, true]
  end

  defp args(%{fun_arity: 2} = req, nil) do
    [Map.get(req, :initial), false]
  end

  defp args(_r, {value}) do
    [value]
  end

  defp args(req, nil) do
    [Map.get(req, :initial)]
  end

  #

  def run_and_reply(%{act: :get} = req, value?) do
    args = args(req, value?)
    from = Map.get(req, :from)
    ret = apply(req.fun, args)

    reply(from, ret) && :id
  end

  def run_and_reply(req, value?) do
    args = args(req, value?)
    from = Map.get(req, :from)

    case apply(req.fun, args) do
      {get} ->
        reply(from, get) && :id

      {get, value} ->
        reply(from, get) && {value}

      :id ->
        reply(from, hd(args)) && :id

      :pop ->
        reply(from, hd(args)) && nil

      malformed ->
        raise CallbackError, got: malformed
    end
  end

  #

  # handle request in a separate task
  def spawn_task(r, value?) do
    server = self()

    Task.start_link(fn ->
      run_and_reply(r, value?)

      send(server, %{info: :done})
    end)

    inc(:processes)
  end

  ##
  ## HANDLE
  ##

  # !
  # this method subjects to an inaccuracy, supposing that
  # each worker holds a value
  # !
  def handle(%{act: :keys}, {values, workers} = state) do
    keys = Map.keys(values) ++ Map.keys(workers)

    {:reply, keys, state}
  end

  def handle(%{act: :values}, {values, workers} = state) do
    w_values = Map.values(values(workers))
    k_values = Map.values(values)

    {:reply, w_values ++ k_values, state}
  end

  def handle(%{act: :to_map}, {values, workers} = state) do
    map =
      workers
      |> values()
      |> Enum.into(values)

    {:reply, map, state}
  end

  #
  # :max_c ≅ :max_concurrency
  #

  # legacy
  def handle(%{key: :max_processes} = req, state) do
    handle(%{req | key: :max_concurrency}, state)
  end

  def handle(%{act: :upd_meta, key: :max_concurrency} = req, state) do
    handle(%{req | key: :max_c}, state)
  end

  def handle(%{act: :upd_meta, key: p, fun: f}, state) do
    arg = Process.get(p)
    ret = f.(arg)

    Process.put(p, ret)

    {:reply, :_done, state}
  end

  #

  def handle(%{act: :meta, key: :real_size}, {values, workers} = state) do
    w_size = map_size(values(workers))
    v_size = map_size(values)

    {:reply, w_size + v_size, state}
  end

  def handle(%{act: :meta, key: :size}, {map, workers} = state) do
    {:reply, map_size(map) + map_size(workers), state}
  end

  def handle(%{act: :meta, key: :max_concurrency} = req, state) do
    handle(%{req | key: :max_c}, state)
  end

  def handle(%{act: :meta, key: p} = req, state) do
    value = Process.get(p, Map.get(req, :initial))
    # value = Process.get(p)

    {:reply, value, state}
  end

  # :tiny

  def handle(%{tiny: true, !: :now} = req, state) do
    run_and_reply(req, collect(req.key, state))

    {:noreply, state}
  end

  def handle(%{tiny: true} = req, {values, workers} = state) do
    worker = workers[req.key]

    state =
      if worker do
        send(worker, to_msg(req))
        # unchanged
        state
      else
        value? = collect(req.key, state)

        case run_and_reply(req, value?) do
          {value} ->
            {Map.put(values, req.key, value), workers}

          nil ->
            {Map.delete(values, req.key), workers}

          :id ->
            # unchanged
            state
        end
      end

    {:noreply, state}
  end

  # tiny: false

  # :get
  def handle(%{!: :now} = req, state) do
    {_s, hard} = Process.get(:max_c)

    if Process.get(:processes) <= hard do
      spawn_task(req, collect(req.key, state))

      {:noreply, state}
    else
      handle(%{req | tiny: true}, state)
    end
  end

  def handle(req, {_map, workers} = state) do
    worker = workers[req.key]

    if worker do
      send(worker, to_msg(req))

      {:noreply, state}
    else
      case req do
        %{act: :get_upd} ->
          handle(req, spawn_worker(state, req.key))

        %{act: :get} ->
          handle(%{req | !: :now}, state)
      end
    end
  end
end

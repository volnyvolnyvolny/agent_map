defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Worker, Server, CallbackError}

  import Server, only: [to_map: 1, spawn_worker: 2]
  import Map, only: [put: 3, fetch: 2, keys: 1, delete: 2]
  import Worker, only: [value?: 1, inc: 1]

  @enforce_keys [:act]

  defstruct [
    :act,
    :initial,
    :from,
    :key,
    :fun,
    !: 255,
    tiny: false
  ]

  #

  def reply(nil, _msg), do: :nothing
  def reply({_p, _ref} = from, msg), do: GenServer.reply(from, msg)
  def reply(from, msg), do: send(from, msg)

  #

  defp collect(key, {map, workers} = _state) do
    case fetch(map, key) do
      {:ok, value} ->
        {value}

      :error ->
        w = workers[key]

        if w, do: value?(w)
    end
  end

  #

  defp args(%{fun: f} = req, value?) do
    init = Map.get(req, :initial)
    value = if value?, do: elem(value?, 0), else: init

    if is_function(f, 2) do
      [value, value? && true]
    else
      [value]
    end
  end

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

  # Compress before sending to worker.
  defp compress(%_{} = req) do
    req
    |> Map.from_struct()
    |> Map.delete(:key)
    |> Enum.reject(&match?({_, nil}, &1))
    |> Enum.reject(&match?({:tiny, false}, &1))
    |> Enum.into(%{})
  end

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

  # this method subjects to an inaccuracy, supposing that
  # each worker holds a value
  def handle(%{act: :keys}, {map, workers} = state) do
    keys = keys(map) ++ Map.keys(workers)
    {:reply, keys, state}
  end

  def handle(%{act: :values}, state) do
    {:reply, to_map(state) |> Map.values(), state}
  end

  def handle(%{act: :to_map}, state) do
    {:reply, to_map(state), state}
  end

  #
  # :max_p ≅ :max_processes
  #

  def handle(%{act: :upd_prop, key: :max_processes} = req, state) do
    handle(%{req | key: :max_p}, state)
  end

  def handle(%{act: :upd_prop, key: prop, fun: f} = req, state) do
    arg = Process.get(prop, Map.get(req, :initial))
    ret = apply(f, [arg])

    Process.put(prop, ret)

    {:reply, :_done, state}
  end

  #

  def handle(%{act: :get_prop, key: :real_size}, state) do
    {:reply, map_size(to_map(state)), state}
  end

  def handle(%{act: :get_prop, key: :size}, {map, workers} = state) do
    {:reply, map_size(map) + map_size(workers), state}
  end

  def handle(%{act: :get_prop, key: :max_processes} = req, state) do
    handle(%{req | key: :max_p}, state)
  end

  def handle(%{act: :get_prop, key: prop} = req, state) do
    value = Process.get(prop, Map.get(req, :initial))

    {:reply, value, state}
  end

  # :tiny

  def handle(%{tiny: true, !: :now} = req, state) do
    run_and_reply(req, collect(req.key, state))

    {:noreply, state}
  end

  def handle(%{tiny: true} = req, {map, workers} = state) do
    worker = workers[req.key]

    state =
      if worker do
        send(worker, compress(req))
        # unchanged
        state
      else
        value? = collect(req.key, state)

        case run_and_reply(req, value?) do
          {value} ->
            {put(map, req.key, value), workers}

          nil ->
            {delete(map, req.key), workers}

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
    {_s, hard} = Process.get(:max_p)

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
      send(worker, compress(req))

      {:noreply, state}
    else
      case req do
        %{act: :upd} ->
          handle(req, spawn_worker(state, req.key))

        %{act: :get} ->
          handle(%{req | !: :now}, state)
      end
    end
  end
end

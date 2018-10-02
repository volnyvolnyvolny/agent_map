defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Worker, Req, Server, Common}

  import Worker, only: [spawn_get_task: 2, dict: 1, processes: 1]
  import Enum, only: [filter: 2]
  import Server.State
  import Common

  @enforce_keys [:action]

  defstruct [
    :action,
    :data,
    :from,
    :key,
    :fun,
    :inserted_at,
    timeout: 5000,
    !: false
  ]

  def timeout(%_{timeout: {_, t}, inserted_at: nil}), do: t
  def timeout(%_{timeout: t, inserted_at: nil}), do: t

  def timeout(%_{} = r) do
    timeout(%{r | inserted_at: nil})
    |> left(since: r.inserted_at)
  end

  def compress(%Req{} = req) do
    req
    |> Map.from_struct()
    |> Map.delete(:key)
    |> compress()
  end

  def compress(%{inserted_at: nil} = map) do
    map
    |> Map.delete(:inserted_at)
    |> Map.delete(:timeout)
    |> compress()
  end

  def compress(%{!: false} = map) do
    map
    |> Map.delete(:!)
    |> compress()
  end

  def compress(map) do
    map
    |> Enum.reject(&match?({_, nil}, &1))
    |> Enum.into(%{})
  end

  ##
  ## HANDLERS
  ##

  def handle(%Req{action: :processes} = req, state) do
    p =
      case get(state, req.key) do
        {_box, {p, _max_p}} ->
          p

        worker ->
          processes(worker)
      end

    {:reply, p, state}
  end

  # per key:
  def handle(%Req{action: :max_processes, key: {key}, data: nil}, state) do
    max_p =
      case get(state, key) do
        {_box, {_p, max_p}} ->
          max_p

        worker ->
          dict(worker)[:max_processes]
      end || Process.get(:max_processes)

    {:reply, max_p, state}
  end

  def handle(%Req{action: :max_processes, key: {key}} = req, state) do
    state =
      case get(state, key) do
        {box, {p, _max_p}} ->
          pack = {box, {p, req.data}}
          put(state, key, pack)

        worker ->
          req = compress(%{req | !: true, from: nil})
          send(worker, req)
      end

    {:noreply, state}
  end

  # per server:
  def handle(%Req{action: :max_processes} = req, state) do
    max_p = Process.put(:max_processes, req.data)
    {:reply, max_p, state}
  end

  #

  def handle(%Req{action: :keys}, state) do
    has_value? = &match?({:ok, _}, fetch(state, &1))
    ks = filter(Map.keys(state), has_value?)

    {:reply, ks, state}
  end

  #

  def handle(%Req{action: :get, !: true} = req, state) do
    case get(state, req.key) do
      {b, {p, max_p}} ->
        spawn_get_task(req, {req.key, b})

        pack = {b, {p + 1, max_p}}
        state = put(state, req.key, pack)
        {:noreply, state}

      worker ->
        b = dict(worker)[:value]
        spawn_get_task(req, {req.key, b})

        send(worker, %{info: :get!})
        {:noreply, state}
    end
  end

  def handle(%Req{action: :get, !: false} = req, state) do
    g_max_p = Process.get(:max_processes)

    case get(state, req.key) do
      # Cannot spawn more Task's.
      {_, {p, nil}} when p >= g_max_p ->
        state = spawn_worker(state, req.key)
        handle(req, state)

      {_, {p, max_p}} when p >= max_p ->
        state = spawn_worker(state, req.key)
        handle(req, state)

      # Can spawn.
      {b, {p, max_p}} ->
        spawn_get_task(req, {req.key, b})
        pack = {b, {p + 1, max_p}}
        state = put(state, req.key, pack)
        {:noreply, state}

      worker ->
        send(worker, compress(req))
        {:noreply, state}
    end
  end

  #

  def handle(%Req{action: :get_and_update} = req, state) do
    case get(state, req.key) do
      {_box, _p_info} ->
        state = spawn_worker(state, req.key)
        handle(req, state)

      worker ->
        send(worker, compress(req))
        {:noreply, state}
    end
  end

  #

  def handle(%Req{action: :put} = req, state) do
    case get(state, req.key) do
      {_box, p_info} ->
        pack = {box(req.data), p_info}
        {:reply, :ok, put(state, req.key, pack)}

      worker ->
        fun = fn _ -> {:ok, req.data} end
        req = %{req | action: :get_and_update, fun: fun}

        send(worker, compress(req))
        {:noreply, state}
    end
  end

  def handle(%Req{action: :put_new} = req, state) do
    case get(state, req.key) do
      {nil, p_info} ->
        pack = {box(req.data), p_info}
        {:reply, :ok, put(state, req.key, pack)}

      {_box, _p_info} ->
        {:reply, :ok, state}

      worker ->
        fun = fn _ ->
          unless Process.get(:value) do
            if req.fun do
              {:ok, req.fun.()}
            else
              {:ok, req.data}
            end
          end || {:ok}
        end

        req = %{req | action: :get_and_update, fun: fun}

        send(worker, compress(req))
        {:noreply, state}
    end
  end

  def handle(%Req{action: :fetch} = req, state) do
    if req.! do
      value = fetch(state, req.key)
      {:reply, value, state}
    else
      fun = fn value ->
        if Process.get(:value) do
          {:ok, value}
        else
          :error
        end
      end

      req = %{req | action: :get, fun: fun}
      handle(req, state)
    end
  end

  def handle(%Req{action: :delete} = req, state) do
    case get(state, req.key) do
      {_box, p_info} ->
        pack = {nil, p_info}
        state = put(state, req.key, pack)
        {:reply, :done, state}

      _worker ->
        req = %{req | action: :get_and_update, fun: fn _ -> :pop end}
        handle(req, state)
    end
  end
end

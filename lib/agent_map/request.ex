defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Worker, Req, Server, Common}

  import Worker, only: [spawn_get_task: 2]
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
        {:pid, w} ->
          Worker.processes(w)

        {_box, {p, _max_p}} ->
          p
      end

    {:reply, p, state}
  end

  def handle(%Req{action: :max_processes, key: nil} = req, {map, max_p}) do
    {:reply, max_p, {map, req.data}}
  end

  def handle(%Req{action: :max_processes} = req, state) do
    case get(state, req.key) do
      {:pid, w} ->
        if req.! do
          max_p = Worker.dict(w)[:"$max_processes"]
          req = compress(%{req | from: nil})
          send(w, req)
          {:reply, max_p, state}
        else
          req = compress(%{req | !: true})
          send(w, req)
          {:noreply, state}
        end

      {box, {p, old_max_p}} ->
        max_p = req.data
        pack = {box, {p, max_p}}
        state = put(state, req.key, pack)
        {:reply, old_max_p, state}
    end
  end

  #

  def handle(%Req{action: :keys}, {map, _} = state) do
    has_value? = &match?({:ok, _}, fetch(state, &1))
    ks = filter(Map.keys(map), has_value?)

    {:reply, ks, state}
  end

  #

  def handle(%Req{action: :get, !: true} = req, state) do
    case get(state, req.key) do
      {:pid, w} ->
        b = Worker.dict(w)[:"$value"]
        spawn_get_task(req, {req.key, b})

        send(w, %{info: :get!})
        {:noreply, state}

      {b, {p, max_p}} ->
        spawn_get_task(req, {req.key, b})

        pack = {b, {p + 1, max_p}}
        state = put(state, req.key, pack)
        {:noreply, state}
    end
  end

  def handle(%Req{action: :get, !: false} = req, state) do
    case get(state, req.key) do
      {:pid, worker} ->
        send(worker, compress(req))
        {:noreply, state}

      # Cannot spawn more Task's.
      {_, {p, max_p}} when p >= max_p ->
        state = spawn_worker(state, req.key)
        handle(req, state)

      # Can spawn.
      {b, {p, max_p}} ->
        spawn_get_task(req, {req.key, b})
        pack = {b, {p + 1, max_p}}
        state = put(state, req.key, pack)
        {:noreply, state}
    end
  end

  #

  def handle(%Req{action: :get_and_update} = req, state) do
    case get(state, req.key) do
      {:pid, w} ->
        send(w, compress(req))
        {:noreply, state}

      _ ->
        state = spawn_worker(state, req.key)
        handle(req, state)
    end
  end

  #

  def handle(%Req{action: :put} = req, state) do
    case get(state, req.key) do
      {:pid, worker} ->
        fun = fn _ -> {:ok, req.data} end
        req = %{req | action: :get_and_update, fun: fun}

        send(worker, compress(req))
        {:noreply, state}

      {_, p_info} ->
        pack = {box(req.data), p_info}
        {:reply, :ok, put(state, req.key, pack)}
    end
  end

  def handle(%Req{action: :fetch} = req, state) do
    value = fetch(state, req.key)
    {:reply, value, state}
  end

  def handle(%Req{action: :delete} = req, state) do
    case get(state, req.key) do
      {_box, p_info} ->
        pack = {nil, p_info}
        state = put(state, req.key, pack)
        {:reply, :done, state}

      _ ->
        req = %{req | action: :get_and_update, fun: fn _ -> IO.inspect(:pop) end}
        handle(req, state)
    end
  end
end

defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Worker, Req, Server, Common}

  import Worker, only: [spawn_get_task: 2]
  import Enum, only: [count: 2, filter: 2]
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

  # XNOR
  defp _filter(%{info: _}, _), do: false
  defp _filter(msg, !: true), do: msg[:!]
  defp _filter(msg, !: false), do: not msg[:!]
  defp _filter(_, []), do: true

  def handle(%Req{action: :queue_len} = req, state) do
    num =
      case get(state, req.key) do
        {:pid, w} ->
          opts = req.data
          count(Worker.queue(w), &_filter(&1, opts))

        _ ->
          0
      end

    {:reply, num, state}
  end

  def handle(%Req{action: :keys}, {map, _} = state) do
    has_value? = &match?({:ok, _}, fetch(state, &1))
    ks = filter(Map.keys(map), has_value?)

    {:reply, ks, state}
  end

  def handle(%Req{action: :max_processes, key: nil} = req, {map, max_p}) do
    {:reply, max_p, {map, req.data}}
  end

  def handle(%Req{action: :max_processes} = req, state) do
    case get(state, req.key) do
      {:pid, w} ->
        if req.! do
          max_p = Worker.dict(w)[:"$max_processes"]
          send(w, IO.inspect(compress(%{req | from: nil})))
          {:reply, max_p, state}
        else
          send(w, IO.inspect(compress(%{req | !: true})))
          {:noreply, state}
        end

      {box, {p, old_max_p}} ->
        max_p = req.data
        state = put(state, req.key, {box, {p, max_p}})
        {:reply, old_max_p, state}
    end
  end

  def handle(%Req{action: :fetch} = req, state) do
    {:reply, fetch(state, req.key), state}
  end

  def handle(%Req{action: :get, !: true} = req, state) do
    state =
      case get(state, req.key) do
        {:pid, w} ->
          b = Worker.dict(w)[:"$value"]

          req
          |> compress()
          |> spawn_get_task({req.key, b})

          send(w, %{info: :get!})
          state

        {b, {p, max_p}} ->
          spawn_get_task({req.key, b}, compress(req))
          put(state, req.key, {b, {p + 1, max_p}})
      end

    {:noreply, state}
  end

  def handle(%Req{action: :get, !: false} = req, state) do
    case get(state, req.key) do
      {:pid, worker} ->
        send(worker, compress(req))
        {:noreply, state}

      # Cannot spawn more Task's.
      {_, {p, max_p}} when p >= max_p ->
        handle(req, spawn_worker(state, req.key))

      # Can spawn.
      {b, {p, max_p}} ->
        spawn_get_task(req, b)
        {:noreply, put(state, req.key, {b, {p + 1, max_p}})}
    end
  end

  def handle(%Req{action: :get_and_update} = req, state) do
    case get(state, req.key) do
      {:pid, w} ->
        send(w, compress(req))
        {:noreply, state}

      _ ->
        handle(req, spawn_worker(state, req.key))
    end
  end

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
end

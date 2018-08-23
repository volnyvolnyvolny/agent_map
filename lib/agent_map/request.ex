defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Common, Worker, Transaction, Req}

  import Worker, only: [queue: 1, dict: 1]
  import Common, only: [unbox: 1, extract: 2, run: 2, spawn_get: 4, handle_timeout_error: 1]
  import Enum, only: [count: 2, filter: 2]

  @enforce_keys [:action]

  # action: :get, :get_and_update, :update, :cast, :keys, …
  # data: {key, fun}, {fun, keys}, …
  # from: nil | GenServer.from
  # timeout: timeout | {:drop | :break, timeout}
  defstruct [
    :action,
    :data,
    :from,
    :inserted_at,
    timeout: 5000,
    !: false
  ]

  ##
  ## MESSAGES TO WORKER
  ##

  defp to_msg(req) when is_function(fun, 1) do
    {_, fun} = req.data
    to_msg(req, req.action, fun)
  end

  defp to_msg(req, act, f) do
    req
    |> Map.from_struct()
    |> Map.delete(:data)
    |> Map.put(:action, act)
    |> Map.put(:fun, f)
  end

  ##
  ## FETCH
  ##

  def get_value(key, state) do
    case extract(key, state) do
      {:pid, worker} ->
        dict(worker)[:"$value"]

      {box, _} ->
        box
    end
  end

  ##
  ## STATE
  ##

  def spawn_worker(key, state) do
    {map, max_p} = state

    case extract(key, state) do
      {:pid, _} ->
        state

      {_, {_, _}} = pack ->
        ref = make_ref()

        worker =
          spawn_link(fn ->
            Worker.loop({ref, self()}, key, pack)
          end)

        receive do
          {^ref, :ok} ->
            :continue
        end

        map = %{map | key => {:pid, worker}}
        {map, max_p}
    end
  end

  ##
  ## HANDLERS
  ##

  # XNOR
  defp _filter(%{info: _}, _), do: false
  defp _filter(msg, !: true), do: msg[:!]
  defp _filter(msg, !: false), do: not msg[:!]
  defp _filter(msg, []), do: true

  def handle(%{action: :queue_len} = req, state) do
    {key, opts} = req.data

    num =
      case extract(key, state) do
        {:pid, worker} ->
          count(queue(worker), &_filter(&1, opts))

        _ ->
          0
      end

    {:reply, num, state}
  end

  def handle(%{action: :keys}, state) do
    {map, _} = state

    keys =
      Map.keys(map)
      |> filter(&get_value(&1, state))

    {:reply, keys, state}
  end

  def handle(%{action: :values} = req, state) do
    {map, _} = state

    fun = fn _ ->
      Map.values(Process.get(:"$map"))
    end

    keys = Map.keys(map)
    req = %{req | action: :get, data: {fun, keys}}
    Transaction.handle(req, state)
  end

  def handle(%{action: :max_processes} = req, state) do
    {key, new_max_p} = req.data

    case extract(key, state) do
      {:pid, worker} ->
        msg = %{info: :max_processes, data: new_max_p}
        send(worker, msg)
        {:noreply, state}

      {box, {p, old_max_p}} ->
        pack = {box, {p, new_max_p}}
        state = inject(key, pack, state)
        {:reply, old_max_p, state}
    end
  end

  def handle(%{action: :max_processes} = req, state) do
    {map, old_max_p} = state

    {:reply, old_max_p, {map, req.data}}
  end

  def handle(%{action: :fetch, data: key} = req, state) do
    r =
      case get_value(key, state) do
        {:value, v} ->
          {:ok, v}

        nil ->
          :error
      end

    {:reply, r, state}
  end

  # Any transaction.
  def handle(%{data: {_fun, keys}} = req, map) when is_list(keys) do
    Transaction.handle(req, map)
  end

  def handle(%{action: :get, !: true} = req, state) do
    {k, fun} = req.data

    box = get_value(key, state)
    spawn_get({key, box}, req)

    {:noreply, state}
  end

  def handle(%{action: :get, !: false} = req, state) do
    {k, fun} = req.data

    case extract(key, state) do
      {:pid, worker} ->
        send(worker, to_msg(req))

      # Cannot spawn more Task's.
      {_, {p, p}} ->
        handle(req, spawn_worker(key, state))

      # Can spawn.
      {box, {p, custom_max_p}} ->
        spawn_get({key, box}, req, self())

        pack = {box, {p + 1, custom_max_p}}
        state = inject(key, pack, state)
        {:noreply, state}
    end
  end

  def handle(%{action: :put} = req, state) do
    {key, v} = req.data

    case extract(key, state) do
      {:pid, worker} ->
        fun = fn _ -> {:ok, v} end
        msg = to_msg(req, :get_and_update, fun)
        send(worker, msg)
        {:noreply, state}

      {_, p_info} ->
        pack = {{:value, v}, p_info}
        state = inject(key, pack, state)
        {:reply, :ok, state}
    end
  end

  # :get_and_update
  def handle(%{action: :get_and_update} = req, state) do
    {key, _} = req.data

    case extract(key, state) do
      {:pid, worker} ->
        send(worker, to_msg(req))
        {:noreply, state}

      _ ->
        handle(req, spawn_worker(key, state))
    end
  end
end

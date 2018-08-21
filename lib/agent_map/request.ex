defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Common, Worker, Transaction, Req}

  import Worker, only: [queue: 1, dict: 1]
  import Common, only: [unbox: 1, run: 2, spawn_get: 4, handle_timeout_error: 1]
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

  defp to_msg(%{data: {_, fun}} = req) when is_function(fun, 1) do
    to_msg(req, req.action, fun)
  end

  defp to_msg(req, act, f) do
    req =
      req
      |> Map.from_struct()
      |> Map.delete(:data)

    %{req | action: act, fun: f}
  end

  ##
  ## FETCH
  ##

  def get_value(key, state) do
    case unpack(key, state) do
      {:pid, worker} ->
        dict(worker)[:"$value"]

      {value, _} ->
        value
    end
  end

  ##
  ## STATE
  ##

  def spawn_worker(key, state) do
    {map, max_p} = state

    case unpack(key, state) do
      {:pid, _} ->
        state

      pack ->
        ref = make_ref()

        worker =
          spawn_link(fn ->
            Worker.loop({ref, self()}, key, pack)
          end)

        receive do
          {^ref, _} ->
            :continue
        end

        {%{map | key => {:pid, worker}}, max_p}
    end
  end

  ##
  ## HANDLERS
  ##

  # XNOR
  defp _filter(%{info: _}, !: true), do: false
  defp _filter(msg, !: true), do: msg[:!]
  defp _filter(msg, !: false), do: not msg[:!]
  defp _filter(msg, []), do: true

  def handle(%{action: :queue_len} = req, state) do
    {key, opts} = req.data

    num =
      case unpack(key, state) do
        {:pid, worker} ->
          count(queue(worker), &_filter(&1, opts))

        _ ->
          0
      end

    {:reply, num, state}
  end

  def handle(%{action: :keys}, state) do
    keys = filter(Map.keys(map), &get_value(&1, state))

    {:reply, keys, state}
  end

  def handle(%{action: :values} = req, {map, _} = state) do
    fun = fn _ ->
      Map.values(Process.get(:"$map"))
    end

    handle(%{req | action: :get, data: {fun, Map.keys(map)}}, state)
  end

  def handle(%{action: :max_processes, data: {key, new_max_p}} = req, state) do
    case unpack(key, state) do
      {:pid, worker} ->
        msg = %{req | info: :max_processes, data: new_max_p}
        send(worker, msg)
        {:noreply, state}

      {value, {p, old_max_p}} ->
        state = pack(key, value, {p, new_max_p}, state)
        {:reply, old_max_p, state}
    end
  end

  def handle(%{action: :max_processes, data: max_processes} = req, {map, old_one}) do
    {:reply, old_one, {map, max_processes}}
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
    spawn_get(key, box, req)

    {:noreply, state}
  end

  def handle(%{action: :get, !: false} = req, {map, max_p} = state) do
    {k, fun} = req.data

    case unpack(key, state) do
      {:pid, worker} ->
        send(worker, to_msg(req))

      # Cannot spawn more Task's.
      {_, {p, p}} ->
        state = spawn_worker(key, state)
        handle(req, state)

      # Can spawn.
      {b, {p, custom_max_p}} ->
        box = get_value(key, state)
        spawn_get(key, box, req, self())

        state = pack(key, b, {p + 1, custom_max_p}, state)
        {:noreply, state}
    end
  end

  def handle(%{action: :put} = req, state) do
    {key, v} = req.data

    case unpack(key, state) do
      {:pid, worker} ->
        fun = fn _ -> {:ok, v} end
        msg = to_msg(req, :get_and_update, fun)
        send(worker, msg)
        {:noreply, state}

      {_old_value, p_info} ->
        box = {:value, v}
        state = pack(key, box, p_info, state)
        {:reply, :ok, state}
    end
  end

  # :get_and_update
  def handle(%{action: :get_and_update} = req, state) do
    {key, _} = req.data

    case unpack(key, state) do
      {:pid, worker} ->
        send(worker, to_msg(req))
        {:noreply, state}

      _ ->
        handle(req, spawn_worker(key, state))
    end
  end
end

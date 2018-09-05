defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Worker, Req, Server.State, Common}

  import Worker, only: [queue: 1, dict: 1, run_and_reply: 3]
  import Enum, only: [count: 2, filter: 2]
  import System, only: [system_time: 0]
  import Common, only: [to_ms: 1]
  import State

  @enforce_keys [:action]

  # action: :get | :get_and_update | :max_processes | :queue_len | …
  # data: {key, fun} | {fun, keys} | {key, max_p} | …
  # from: nil | GenServer.from
  # timeout: timeout | {:drop | :break, pos_integer}
  defstruct [
    :action,
    :data,
    :from,
    :inserted_at,
    timeout: 5000,
    !: false
  ]

  def timeout(%Req{timeout: t}), do: timeout(t)
  def timeout({_, t}), do: t
  def timeout(t), do: t

  def left(:infinity, _), do: :infinity

  def left(timeout, since: past) do
    timeout - to_ms(system_time() - past)
  end

  # Drops struct field.
  def to_msg(req, act, f) do
    req
    |> Map.from_struct()
    |> Map.put(:action, act)
    |> Map.put(:fun, f)
    |> compress()
  end

  ## Remove fields that are not used.
  def compress(%Req{action: :max_processes, data: {_, max_p}}) do
    %{action: :max_processes, !: true, data: max_p}
  end

  def compress(%Req{data: {_, f}} = req) when is_function(f, 1) do
    to_msg(req, req.action, f)
  end

  def compress(%Req{data: {f, _}} = req) when is_function(f, 1) do
    to_msg(req, req.action, f)
  end

  def compress(%{data: _, fun: _} = msg) do
    compress(Map.delete(msg, :data))
  end

  def compress(%{from: nil} = msg) do
    compress(Map.delete(msg, :from))
  end

  def compress(%{timeout: {_, _}} = msg), do: msg

  def compress(msg) do
    msg
    |> Map.delete(:timeout)
    |> Map.delete(:inserted_at)
  end

  defp spawn_get_task(%{data: {k, fun}} = req, b) do
    server = self()

    Task.start_link(fn ->
      Process.put(:"$key", k)
      Process.put(:"$value", b)

      opts = compress(req)
      run_and_reply(fun, unbox(b), opts)

      send(server, %{info: :done, key: k})
    end)
  end

  ##
  ## HANDLERS
  ##

  # XNOR
  defp _filter(%{info: _}, _), do: false
  defp _filter(msg, !: true), do: msg[:!]
  defp _filter(msg, !: false), do: not msg[:!]
  defp _filter(_, []), do: true

  def handle(%Req{action: :queue_len, data: {key, opts}}, state) do
    num =
      case get(state, key) do
        {:pid, worker} ->
          count(queue(worker), &_filter(&1, opts))

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

  def handle(%Req{action: :max_processes, data: {key, max_p}} = req, state) do
    case get(state, key) do
      {:pid, worker} ->
        if req.! do
          max_p = dict(worker)[:"$max_processes"]
          send(worker, compress(%{req | from: nil}))
          {:reply, max_p, state}
        else
          send(worker, compress(req))
          {:noreply, state}
        end

      {box, {p, old_max_p}} ->
        state = put(state, key, {box, {p, max_p}})
        {:reply, old_max_p, state}
    end
  end

  def handle(%Req{action: :max_processes} = req, {map, max_p}) do
    {:reply, max_p, {map, req.data}}
  end

  def handle(%Req{action: :fetch, data: key}, state) do
    {:reply, fetch(state, key), state}
  end

  def handle(%Req{action: :get, !: true, data: {key, _}} = req, state) do
    state =
      case get(state, key) do
        {:pid, worker} ->
          b = dict(worker)[:"$value"]
          spawn_get_task(req, b)
          send(worker, %{info: :get!})
          state

        {b, {p, max_p}} ->
          spawn_get_task(req, b)
          put(state, key, {b, {p + 1, max_p}})
      end

    {:noreply, state}
  end

  def handle(%Req{action: :get, !: false, data: {key, _}} = req, state) do
    case get(state, key) do
      {:pid, worker} ->
        send(worker, compress(req))
        {:noreply, state}

      # Cannot spawn more Task's.
      {_, {p, max_p}} when p >= max_p ->
        handle(req, spawn_worker(state, key))

      # Can spawn.
      {b, {p, max_p}} ->
        spawn_get_task(req, b)
        {:noreply, put(state, key, {b, {p + 1, max_p}})}
    end
  end

  # :get_and_update
  def handle(%Req{action: :get_and_update, data: {key, _}} = req, state) do
    case get(state, key) do
      {:pid, worker} ->
        send(worker, compress(req))
        {:noreply, state}

      _ ->
        handle(req, spawn_worker(state, key))
    end
  end

  def handle(%Req{action: :put, data: {key, v}} = req, state) do
    case get(state, key) do
      {:pid, worker} ->
        fun = fn _ -> {:ok, v} end
        msg = to_msg(req, :get_and_update, fun)
        send(worker, msg)
        {:noreply, state}

      {_, p_info} ->
        pack = {box(v), p_info}
        {:reply, :ok, put(state, key, pack)}
    end
  end
end

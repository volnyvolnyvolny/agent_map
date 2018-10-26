defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Req, Worker, Server.State, Time}

  import Worker, only: [dict: 1, info: 2]
  import Time, only: [now: 0]
  import State, only: [put: 3, get: 2]

  use GenServer

  ##
  ## GenServer callbacks
  ##

  @impl true
  def init(args) do
    timeout = args[:timeout]

    funs = args[:funs]
    keys = Keyword.keys(funs)

    results =
      funs
      |> Enum.map(fn {_key, fun} ->
        Task.async(fn ->
          AgentMap.safe_apply(fun, [])
        end)
      end)
      |> Task.yield_many(timeout)
      |> Enum.map(fn {task, res} ->
        res || Task.shutdown(task, :brutal_kill)
      end)
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, _reason} = e ->
          {:error, e}

        nil ->
          {:error, :timeout}
      end)
      |> Enum.zip(keys)

    errors =
      for {{:error, reason}, key} <- results do
        {key, reason}
      end

    if Enum.empty?(errors) do
      map =
        for {{:ok, v}, key} <- results, into: %{} do
          {key, {:value, v}}
        end

      max_p = args[:max_processes]

      Process.put(:max_processes, max_p)

      {:ok, map}
    else
      {:stop, errors}
    end
  end

  ##
  ## CALL / CAST
  ##

  @impl true
  def handle_call(%r{} = req, from, state) do
    r.handle(%{req | from: from, inserted_at: now()}, state)
  end

  @impl true
  def handle_cast(%r{} = req, state) do
    case r.handle(%{req | inserted_at: now()}, state) do
      {:reply, _, state} ->
        {:noreply, state}

      noreply ->
        noreply
    end
  end

  ##
  ## INFO
  ##

  @impl true
  def handle_info(%{info: :done, key: key} = msg, state) do
    state =
      case get(state, key) do
        {b, {p, max_p}} ->
          pack = {b, {p - 1, max_p}}
          put(state, key, pack)

        worker ->
          send(worker, msg)
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({worker, :die?}, state) do
    # Msgs could came during a small delay between
    # this call happen and :die? was sent.
    unless info(worker, :message_queue_len) > 0 do
      #!
      dict = dict(worker)
      send(worker, :die!)

      #!
      m = dict[:max_processes]
      p = dict[:processes]
      b = dict[:value]
      k = dict[:key]

      pack = {b, {p - 1, m}}

      {:noreply, put(state, k, pack)}
    else
      {:noreply, state}
    end
  end

  ##
  ## CODE CHANGE
  ##

  @impl true
  def code_change(_old, state, fun) do
    state =
      Enum.reduce(Map.keys(state), state, fn key, state ->
        req = %Req{action: :cast, key: key, fun: fun, !: 65537}

        case Req.handle(req, state) do
          {:reply, _, state} ->
            state

          {:noreply, state} ->
            state
        end
      end)

    {:ok, state}
  end
end

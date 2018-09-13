defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Req, Worker, Server.State, Common}

  import State, only: [put: 3, get: 2]
  import Common, only: [now: 0]

  use GenServer

  ##
  ## GenServer callbacks
  ##

  @impl true
  def init(args) do
    keys = Keyword.keys(args[:funs])

    results =
      args[:funs]
      |> Enum.map(fn {_key, fun} ->
        Task.async(fn ->
          AgentMap.safe_apply(fun, [])
        end)
      end)
      |> Task.yield_many(args[:timeout])
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

      {:ok, {map, args[:max_processes]}}
    else
      {:stop, errors}
    end
  end

  ##
  ## CALL
  ##

  @impl true
  def handle_call(%_{from: nil} = req, from, state) do
    handle_call(%{req | from: from}, :_from, state)
  end

  @impl true
  def handle_call(%_{timeout: {_, _t}, inserted_at: nil} = req, from, state) do
    handle_call(%{req | inserted_at: now()}, from, state)
  end

  @impl true
  def handle_call(%r{} = req, _from, state) do
    r.handle(req, state)
  end

  ##
  ## CAST
  ##

  @impl true
  def handle_cast(%_{timeout: {_, _t}, inserted_at: nil} = req, state) do
    handle_cast(%{req | inserted_at: now()}, state)
  end

  @impl true
  def handle_cast(%r{} = req, state) do
    case r.handle(req, state) do
      {:reply, _, state} ->
        {:noreply, state}

      noreply ->
        {:noreply, noreply}
    end
  end

  ##
  ## INFO
  ##

  @impl true
  def handle_info(%{info: :done, key: key} = msg, state) do
    state =
      case get(state, key) do
        {:pid, worker} ->
          send(worker, msg)
          state

        {b, {p, max_p}} ->
          pack = {b, {p - 1, max_p}}
          put(state, key, pack)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({pid, :die?}, state) do
    # Msgs could came during a small delay between
    # this call happen and :die? was sent.
    state =
      if Worker.queue_len(pid) == 0 do
        #!
        dict = Worker.dict(pid)
        send(pid, :die!)

        #!
        m = dict[:"$max_processes"]
        p = dict[:"$processes"]
        b = dict[:"$value"]
        k = dict[:"$key"]

        pack = {b, {p - 1, m}}
        put(state, k, pack)
      end || state

    {:noreply, state}
  end

  ##
  ## CODE CHANGE
  ##

  @impl true
  def code_change(_old, {map, _max_p} = state, fun) do
    state =
      Enum.reduce(Map.keys(map), state, fn key, state ->
        req = %Req{action: :cast, key: key, fun: fun}

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

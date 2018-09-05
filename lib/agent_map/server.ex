defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Req, Worker, Transaction, Server.State, Common}

  import System, only: [system_time: 0]
  import State, only: [put: 3, get: 2]
  import Common, only: [now: 0]

  use GenServer

  def safe_apply(fun, args) do
    {:ok, apply(fun, args)}
  rescue
    BadFunctionError ->
      {:error, :badfun}

    BadArityError ->
      {:error, :badarity}

    exception ->
      {:error, exception}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  ##
  ## GenServer callbacks
  ##

  def init(args) do
    keys = Keyword.keys(args[:funs])

    results =
      args[:funs]
      |> Enum.map(fn {_key, fun} ->
        Task.async(fn ->
          safe_apply(fun, [])
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

  def handle_call(%{from: nil} = req, f, state) do
    handle_call(%{req | from: f}, :_, state)
  end

  def handle_call(%{timeout: {_, _}, inserted_at: nil} = req, :_, state) do
    handle_call(%{req | inserted_at: now()}, :_, state)
  end

  # This call must be made in one go.
  def handle_call(%{action: :values} = req, :_, state) do
    {map, _} = state

    fun = fn _ ->
      Map.values(Process.get(:"$map"))
    end

    req = %{req | action: :get, data: {fun, Map.keys(map)}}
    handle_call(req, :_, map)
  end

  def handle_call(%{data: {_fun, keys}} = req, :_, state) when is_list(keys) do
    Transaction.handle(req, state)
  end

  def handle_call(req, :_, state) do
    Req.handle(req, state)
  end

  ##
  ## CAST
  ##

  def handle_cast(%{timeout: {_, _}, inserted_at: nil} = req, state) do
    handle_cast(%{req | inserted_at: now()}, state)
  end

  def handle_cast(%{data: {_fun, keys}} = req, state) when is_list(keys) do
    Transaction.handle(req, state)
  end

  def handle_cast(req, state) do
    case Req.handle(req, state) do
      {:reply, _, state} ->
        {:reply, {:noreply, state}}

      noreply ->
        {:noreply, noreply}
    end
  end

  ##
  ## INFO
  ##

  def handle_info(%{info: :done, key: key} = msg, state) do
    state =
      case get(state, key) do
        {:pid, worker} ->
          send(worker, msg)
          state

        {value, {p, max_p}} ->
          pack = {value, {p - 1, max_p}}
          put(state, key, pack)
      end

    {:noreply, state}
  end

  def handle_info({w, :mayidie?}, state) do
    # Msgs could came during a small delay between
    # this call happend and :mayidie? was sent.
    if Worker.queue_len(w) > 0 do
      send(w, :continue)
      {:noreply, state}
    else
      #!
      dict = Worker.dict(w)
      send(w, :die!)

      #!
      p = dict[:"$processes"]
      v = dict[:"$value"]
      k = dict[:"$key"]

      pack = {v, {p - 1, dict[:"$max_processes"]}}
      state = put(state, k, pack)
      {:noreply, state}
    end
  end

  ##
  ##
  ##

  def code_change(_old, {map, _max_p} = state, fun) do
    state =
      Enum.reduce(Map.keys(map), state, fn key, state ->
        req = %Req{action: :cast, data: {key, fun}}

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

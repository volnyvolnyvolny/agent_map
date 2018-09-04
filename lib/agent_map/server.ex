defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Common, Req, Worker}

  import System, only: [system_time: 0]
  import Common, only: [put: 3, get: 2]
  import Worker, only: [dict: 1, queue_len: 1]

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

  def handle_call(%{timeout: {_, _}, inserted_at: nil} = req, from, state) do
    IO.inspect(:a)
    handle_call(%{req | inserted_at: system_time()}, from, state)
  end

  def handle_call(req, from, state) do
    IO.inspect(:b)
    Req.handle(%{req | from: from}, state)
  end

  ##
  ## CAST
  ##

  def handle_cast(%{timeout: {_, _}, inserted_at: nil} = req, state) do
    handle_cast(%{req | inserted_at: system_time()}, state)
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

        {value, {p, custom_max_p}} ->
          pack = {value, {p - 1, custom_max_p}}
          put(state, key, pack)
      end

    {:noreply, state}
  end

  def handle_info({worker, :mayidie?}, state) do
    # Msgs could came during a small delay between
    # this call happend and :mayidie? was sent.
    if queue_len(worker) > 0 do
      send(worker, :continue)
      {:noreply, state}
    else
      dict = dict(worker)
      send(worker, :die!)

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

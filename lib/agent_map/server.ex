defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Common, Req, Worker}

  import System, only: [system_time: 0]
  import Common, only: [pack: 4, unpack: 2]
  import Worker, only: [dict: 1, queue_len: 1]
  import Map, only: [delete: 2]

  use GenServer

  ##
  ## The state of this GenServer is a pair:
  ##
  ##   {map, default `max_processes` (max_p)}
  ##
  ## For each map key, value is one of the:
  ##
  ##   * {:pid, worker}
  ##
  ##   * {{:value, v}, {processes, max_p}}
  ##   * {{:value, v}, p}
  ##     = {{:value, v}, {p, max_p by def.}}
  ##   * {:value, v}
  ##     = {{:value, v}, {0, max_p by def.}}
  ##
  ## No value:
  ##
  ##   * {nil, {processes, max_p}}
  ##   * {nil, processes}
  ##     = {nil, {process, max_p by def.}}
  ##

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
    results =
      args[:funs]
      |> Enum.map(fn {_key, fun} ->
        Task.async(fn ->
          safe_apply(fun, [])
        end)
      end)
      |> Task.yield_many(timeout)
      |> Enum.map(fn {task, res} ->
        res || Task.shutdown(task, :brutal_kill)
      end)
      |> Enum.map(fn
        {:ok, _result} = id ->
          id

        nil ->
          {:error, :timeout}
      end)

    {kv, errors} =
      args[:funs]
      |> Keyword.keys()
      |> Enum.zip(results)
      |> Enum.split_with(&match?({:ok, _}, &1))

    if [] == errors do
      # no errors
      map =
        for {key, {:ok, v}} <- kv, into: %{} do
          {key, {:value, v}}
        end

      {:ok, {map, args[:max_processes]}}
    else
      reason =
        for {key, {:error, reason}} <- errors do
          {key, reason}
        end

      {:stop, reason}
    end
  end

  ##
  ## CALL
  ##

  def handle_call(%{timeout: {_, _}, inserted_at: nil} = req, from, state) do
    handle_call(%{req | inserted_at: system_time()}, from, state)
  end

  def handle_call(req, from, state) do
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
        {:noreply, state}

      {:noreply, _} = r ->
        r
    end
  end

  ##
  ## INFO
  ##

  def handle_info(%{info: :done, key: key} = msg, state) do
    state =
      case unpack(key, state) do
        {:pid, worker} ->
          send(worker, msg)
          state

        {value, {p, custom_max_p}} ->
          pack(key, value, {p - 1, custom_max_p}, state)
      end

    {:noreply, state}
  end

  def handle_info({worker, :mayidie?}, {map, max_p} = state) do
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

      state = pack(k, v, {p - 1, dict[:"$max_processes"]}, state)
      {:noreply, state}
    end
  end

  def handle_info(msg, state), do: super(msg, state)

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

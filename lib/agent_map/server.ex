defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Common, Req, Worker}

  import Map, only: [delete: 2]
  import Worker, only: [queue_len: 1]
  import System, only: [system_time: 0]
  import Common, only: [run_group: 2, dict: 1]
  import Req, only: [box: 4, get_state: 1]

  use GenServer

  ##
  ## The state of this GenServer is a pair:
  ##
  ##   {map, default max_processes value}
  ##
  ## For each map key, value is one of the:
  ##
  ##   * {:pid, worker}
  ##
  ##   * {{:value, v}, {processes, max_processes}}
  ##   * {{:value, v}, processes}
  ##     = {{:value, v}, {processes, @max_processes}}
  ##   * {:value, v}
  ##     = {{:value, v}, {0, @max_processes}}
  ##
  ## No value:
  ##
  ##   * {nil, {processes, max_processes}}
  ##   * {nil, processes}
  ##     = {nil, process, @max_processes}
  ##

  ##
  ## GenServer callbacks
  ##

  def init(args) do
    results =
      args[:funs]
      |> Keyword.values()
      |> run_group(args[:timeout])

    {kv, errors} =
      args[:funs]
      |> Keyword.keys()
      |> Enum.zip(results)
      |> Enum.split_with(&match?({:ok, _}, &1))

    if [] == errors do
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

  def handle_call(%{timeout: {:drop, _}, inserted_at: nil} = req, from, state) do
    handle_call(%{req | inserted_at: system_time()}, from, state)
  end

  def handle_call(%{timeout: {:break, _}, inserted_at: nil} = req, from, state) do
    handle_call(%{req | inserted_at: system_time()}, from, state)
  end

  def handle_call(req, from, state) do
    Req.handle(%{req | from: from}, state)
  end

  def handle_cast(%{timeout: {:drop, _}, inserted_at: nil} = req, state) do
    handle_cast(%{req | inserted_at: system_time()}, state)
  end

  def handle_cast(%{timeout: {:stop, _}, inserted_at: nil} = req, state) do
    handle_cast(%{req | inserted_at: system_time()}, state)
  end

  def handle_cast(req, state) do
    state =
      req
      |> Req.handle(state)
      |> get_state()

    {:noreply, state}
  end

  ##
  ## INFO
  ##

  def handle_info(%{info: :done, key: key} = msg, {map, max_p} = state) do
    state =
      case map[key] do
        {:pid, worker} ->
          send(worker, msg)
          state

        {nil, 1} ->
          {delete(map, key), max_p}

        {value, {p, custom_max_p}} ->
          {%{map | key => {value, {p - 1, custom_max_p}}}, max_p}

        {value, p} ->
          {%{map | key => {value, p - 1}}, max_p}
      end

    {:noreply, state}
  end

  def handle_info(%{action: :chain} = req, state) do
    Req.handle(struct(Req, %{req | action: :get_and_update}), state)
  end

  # Worker asks to exit.
  def handle_info({worker, :mayidie?}, {map, max_p} = state) do
    # Msgs could came during a small delay between
    # this call happend and :mayidie? was sent.
    if queue_len(worker) > 0 do
      send(worker, :continue)
      {:noreply, state}
    else
      dict = dict(worker)
      send(worker, :die!)

      p = dict[:"$processes"]
      v = dict[:"$value"]

      case box(v, p - 1, dict[:"$max_processes"], max_p) do
        nil ->
          # GC
          map = delete(map, dict[:"$key"])
          {:noreply, {map, max_p}}

        box ->
          map = %{map | dict[:"$key"] => box}
          {:noreply, {map, max_p}}
      end
    end
  end

  def handle_info(msg, state) do
    super(msg, state)
  end

  def code_change(_old, {map, _max_p} = state, fun) do
    state =
      Enum.reduce(Map.keys(map), state, fn key, state ->
        %Req{action: :cast, data: {key, fun}}
        |> Req.handle(state)
        |> get_state()
      end)

    {:ok, state}
  end
end

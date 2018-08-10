defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Common, Req, Worker}

  import Map, only: [delete: 2]
  import Worker, only: [queue_len: 1, dict: 1]
  import System, only: [system_time: 0]
  import Common, only: [run_group: 2]

  use GenServer

  @max_processes 5

  ##
  ## The state of this GenServer is a pair:
  ##
  ##   {map, default max_processes value, map}
  ##
  ## For each map key, value is one of the:
  ##
  ##  * {:pid, worker}
  ##  * {:value, value}
  ##
  ##  * {{:value, value}, {processes, max_processes}}
  ##  * {{:value, v}, processes}
  ##    == {{:value, v}, {processes, @max_processes}}
  ##
  ##  No value:
  ##
  ##  * {nil, {processes, max_processes}}
  ##  * {nil, processes}
  ##    == {nil, process, @max_processes}
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
      {:ok,
       {for {key, {:ok, v}} <- kv, into: %{} do
         {key, {:value, v}}
       end, args[:max_processes]}
    else
      {:stop,
       for {key, {:error, reason}} <- errors do
         {key, reason}
       end}
    end
  end

  def handle_call(%{timeout: {:drop, _}, inserted_at: nil} = req, from, map) do
    handle_call(%{req | inserted_at: system_time()}, from, map)
  end

  def handle_call(%{timeout: {:hard, _}, inserted_at: nil} = req, from, map) do
    handle_call(%{req | inserted_at: system_time()}, from, map)
  end

  def handle_call(req, from, map) do
    Req.handle(%{req | from: from}, map)
  end

  def handle_cast(%{timeout: {:drop, _}, inserted_at: nil} = req, map) do
    handle_cast(%{req | inserted_at: system_time()}, map)
  end

  def handle_cast(%{timeout: {:hard, _}, inserted_at: nil} = req, map) do
    handle_cast(%{req | inserted_at: system_time()}, map)
  end

  def handle_cast(req, map) do
    {:noreply,
     case Req.handle(req, map) do
       {:reply, _r, map} ->
         map

       {:noreply, map} ->
         map
     end}
  end

  ##
  ## INFO
  ##

  def handle_info(%{info: :done, key: key} = msg, map) do
    {:noreply,
     case map[key] do
       {:pid, worker} ->
         send(worker, msg)
         map

       {nil, {1, @max_processes}} ->
         delete(map, key)

       {value, {1, max_p}} ->
         %{map | key => {value, max_p}}

       {value, {p, max_p}} ->
         %{map | key => {value, {p - 1, max_p}}}
     end}
  end

  def handle_info(%{action: :chain} = req, map) do
    Req.handle(struct(Req, %{req | action: :get_and_update}), map)
  end

  # Worker asks to exit.
  def handle_info({worker, :mayidie?}, map) do
    # Msgs could came during a small delay between
    # this call happend and :mayidie? was sent.
    if queue_len(worker) > 0 do
      send(worker, :continue)
      {:noreply, map}
    else
      dict = dict(worker)
      send(worker, :die!)

      p = dict[:"$processes"]
      max_p = dict[:"$max_processes"]

      key = dict[:"$key"]

      state =
        {dict[:"$value"],
         if p == 1 do
           max_p
         else
           {p - 1, max_p}
         end}

      {:noreply,
       if state == {nil, @max_processes} do
         # GC
         delete(map, key)
       else
         %{map | key => state}
       end}
    end
  end

  def handle_info(msg, value) do
    super(msg, value)
  end

  def code_change(_old, map, fun) do
    {:ok,
     Enum.reduce(Map.keys(map), map, fn key, map ->
       %Req{action: :cast, data: {key, fun}}
       |> Req.handle(map)
       |> elem(1)
     end)}
  end
end

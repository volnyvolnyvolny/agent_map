defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Helpers, Req, Worker}

  import Enum, only: [uniq: 1]
  import Map, only: [delete: 2]
  import Worker, only: [queue_len: 1, dict: 1]
  import Helpers, only: [ok?: 1, safe_apply: 2, run: 2]

  use GenServer

  @max_processes 5

  defp box(nil), do: {nil, @max_processes}
  defp box({_value, _max_p} = p), do: p

  def spawn_worker(map, key) do
    ref = make_ref()

    worker =
      spawn_link(fn ->
        Worker.loop({ref, self()}, key, box(map[key]))
      end)

    receive do
      {ref, _} ->
        :continue
    end

    %{map | key => {:pid, worker}}
  end

  ##
  ## GenServer callbacks
  ##

  def init({funs, timeout}) do
    keys = Keyword.keys(funs)

    results =
      funs
      |> Keyword.values()
      |> run(timeout)

    {kv, errors} =
      keys
      |> Enum.zip(results)
      |> Enum.split_with(&ok?/1)

    if [] == errors do
      {:ok,
       for {key, {:ok, v}} <- kv, into: %{} do
         {key, {{:value, v}, @max_processes}}
       end}
    else
      {:stop,
       for {key, {:error, reason}} <- errors do
         {key, reason}
       end}
    end
  end

  def handle_call(req, from, map) do
    Req.handle(%{req | from: from}, map)
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

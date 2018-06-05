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

  defp wait(ref) do
    receive do
      {ref, _} ->
        :continue
    after
      0 ->
        wait(ref)
    end
  end

  def spawn_worker(map, key) do
    ref = make_ref()

    worker =
      spawn_link(fn ->
        Worker.loop({ref, self()}, key, box(map[key]))
      end)

    wait(ref)

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
    map =
      case Req.handle(req, map) do
        {:reply, _r, map} ->
          map

        {_, map} ->
          map
      end

    {:noreply, map}
  end

  ##
  ## INFO
  ##

  def handle_info(%{info: :done} = msg, map) do
    # case map[key] do
    #   {:pid, worker} ->
    #     send(worker, %{msg | on_server?: true})
    #     {:noreply, map}

    #   {nil, @max_processes} ->
    #     {:noreply, delete(map, key)}

    #   {_, :infinity} ->
    #     {:noreply, map}

    #   {value, quota} ->
    #     map = put_in(map[key], {value, quota + 1})
    #     {:noreply, map}

    #   _ ->
    #     {:noreply, map}
    # end
  end

  def handle_info(%{action: :chain} = req, map) do
    Req.handle(%{req | action: :get_and_update}, map)
  end

  # Worker asks to exit.
  def handle_info({worker, :mayidie?}, map) do
    {_, dict} = Process.info(worker, :dictionary)

    # Msgs could came during a small delay between
    # this call happend and :mayidie? was sent.
    if queue_len(worker) > 0 do
      send(worker, :continue)
      {:noreply, map}
    else
      max_t = dict(worker)[:"$max_processes"]
      value = dict(worker)[:"$value"]
      key = dict(worker)[:"$key"]

      send(worker, :die!)

      ### ~BUG
      if {value, max_t} == {nil, @max_processes} do
        # GC
        {:noreply, delete(map, key)}
      else
        map = %{map | key => {value, max_t}}
        {:noreply, map}
      end
    end
  end

  def handle_info(msg, value) do
    super(msg, value)
  end

  def code_change(_old, map, fun) do
    for key <- Map.keys(map) do
      Req.handle(%Req{action: :cast, data: {key, fun}})
    end

    {:ok, map}
  end
end

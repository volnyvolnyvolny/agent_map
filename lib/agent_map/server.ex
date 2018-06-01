defmodule AgentMap.Server do
  @moduledoc false
  require Logger

  alias AgentMap.{Callback, Req, Worker}

  import Enum, only: [uniq: 1]
  import Map, only: [delete: 2]
  import Worker, only: [queue_len: 1, dict: 1]

  use GenServer

  @max_threads 5

  defp wait(ref) do
    receive do
      {ref, _} ->
        :continue
    after
      0 ->
        wait(ref)
    end
  end

  def no_value(), do: {nil, @max_threads}

  def spawn_worker(map, key) do
    value =
      case map[key] do
        nil ->
          no_value()

        {_v, _max_p} = t ->
          t
      end

    ref = make_ref()

    worker =
      spawn_link(fn ->
        Worker.loop({ref, self()}, key, value)
      end)

    wait(ref)

    %{map | key => {:pid, worker}}
  end

  ##
  ## GenServer callbacks
  ##

  def init({funs, timeout}) do
    with keys = Keyword.keys(funs),
         # check for dups
         [] <- keys -- uniq(keys),
         {:ok, results} <- Callback.safe_run(funs, timeout) do
      map =
        for {key, s} <- results, into: %{} do
          {key, {{:value, s}, @max_threads}}
        end

      {:ok, map}
    else
      {:error, reason} ->
        {:stop, reason}

      dup ->
        {:stop,
         for key <- dup do
           {key, :exists}
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

    #   {nil, @max_threads} ->
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
      max_t = dict(worker)[:"$max_threads"]
      value = dict(worker)[:"$value"]
      key = dict(worker)[:"$key"]

      send(worker, :die!)

      ### ~BUG
      if {value, max_t} == {:no, @max_threads} do
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

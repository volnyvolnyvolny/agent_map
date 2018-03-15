defmodule AgentMap.Server do
  @moduledoc false

  alias AgentMap.{Callback, Req}

  import Req, only: [handle: 2]

  import Enum, only: [uniq: 1]
  import Map, only: [delete: 2]

  use GenServer

  @max_threads 5

  ##
  ## GenServer callbacks
  ##

  def init({funs, timeout}) do
    with keys = Keyword.keys(funs),
         [] <- keys--uniq(keys), #check for dups
         {:ok, results} <- Callback.safe_run(funs, timeout) do

      map = for {key, s} <- results, into: %{} do
        {key, {{:value, s}, @max_threads}}
      end
      {:ok, map}
    else
      {:error, reason} ->
        {:stop, reason}
      dup ->
        {:stop, for key <- dup do {key, :exists} end}
    end
  end

  def handle_call(req, from, map) do
    handle %{req | :from => from}, map
  end

  def handle_cast(req, map) do
    handle req, map
  end


  ##
  ## INFO
  ##

  def handle_info({:done_on_server, key}, map) do
    case map[key] do
      {:pid, worker} ->
        send worker, {:!, :done_on_server}
        {:noreply, map}

      {nil, @max_threads} ->
        {:noreply, delete(map, key)}

      {_, :infinity} ->
        {:noreply, map}

      {value, quota} ->
        map = put_in map[key], {value, quota+1}
        {:noreply, map}

      _ ->
        {:noreply, map}
    end
  end

  # worker asks to exit
  def handle_info({worker, :mayidie?}, map) do
    {:dictionary, dict} = Process.info worker, :dictionary

    # msgs could come during a small delay between
    # this call happend and :mayidie? was sent
    {:messages, queue} = Process.info worker, :messages

    if length(queue) > 0 do
      send worker, :continue
      {:noreply, map}
    else
      max_t = dict[:'$max_threads']
      value = dict[:'$value']
      key = dict[:'$key']

      send worker, :die!

      if {value, max_t} == {nil, @max_threads} do
        {:noreply, delete(map, key)} #GC
      else
        map = put_in map[key], {value, max_t}
        {:noreply, map}
      end
    end
  end

  def handle_info(msg, value) do
    super msg, value
  end


  def code_change(_old, value, fun) do
    {:ok, Callback.run(fun, [value])}
  end

end

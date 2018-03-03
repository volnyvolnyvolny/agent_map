defmodule AgentMap.Server do
  @moduledoc false

  alias AgentMap.{Callback, Req}

  import Req, only: [fetch: 2, handle: 2]

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
        {key, {{:state, s}, @max_threads}}
      end
      {:ok, map}
    else
      {:error, reason} ->
        {:stop, reason}
      dup ->
        {:stop, for key <- dup do {key, :already_exists} end}
    end
  end

  ##
  ## HELPERS
  ##

  defp has_key?(map, key) do
    case fetch map, key do
      {:ok, _} -> true
      _ -> false
    end
  end

  ##
  ## IMMEDIATE REPLY
  ##

  def handle_call(:keys,_from, map) do
    keys = for key <- Map.keys( map),
               has_key?(map, key), do: key

    {:reply, keys, map}
  end

  def handle_call({:has_key?, key},_from, map) do
    {:reply, has_key?(map, key), map}
  end

  def handle_call({:queue_len, key},_from, map) do
    case map[key] do
      {:pid, worker} ->
        {:messages, queue} = Process.info worker, :messages
        num = Enum.count queue, fn msg ->
          msg not in [:done, :done_on_server]
        end
        {:reply, num, map}
      _ ->
        {:reply, 0, map}
    end
  end

  def handle_call({:!, {:fetch, key}},_from, map) do
    {:reply, fetch(map, key), map}
  end

  def handle_call({:!, {:take, keys}},_from, map) do
    res = Enum.reduce keys, %{}, fn key, res ->
      case fetch map, key do
        {:ok, state} -> put_in res[key], state
        _ -> res
      end
    end

    {:reply, res, map}
  end

  def handle_call({:!, {:get, key, default}},_from, map) do
    state = case fetch map, key do
      {:ok, state} -> state
      :error -> default
    end

    {:reply, state, map}
  end

  ##
  ## MAY RETURN `{:noreply, …}`
  ##

  def handle_call({:max_threads, key, value}, from, map) do
    case map[key] do
      {:pid, worker} ->
        send worker, {:!, {:max_threads, value, from}}
        {:noreply, map}

      {state, mt} ->
        map = put_in map[key], {state, value}
        {:reply, mt, map}

      nil ->
        map = put_in map[key], {nil, value}
        {:reply, @max_threads, map}
    end
  end

  def handle_call( req, from, map) do
    handle %{req | :from => from}, map
  end

  def handle_cast( req, map) do
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

      {state, quota} ->
        map = put_in map[key], {state, quota+1}
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
      state = dict[:'$state']
      key = dict[:'$key']

      send worker, :die!

      if {state, max_t} == {nil, @max_threads} do
        {:noreply, delete(map, key)} #GC
      else
        map = put_in map[key], {state, max_t}
        {:noreply, map}
      end
    end
  end

  def handle_info(msg, state) do
    super msg, state
  end


  def code_change(_old, state, fun) do
    {:ok, Callback.run(fun, [state])}
  end

end

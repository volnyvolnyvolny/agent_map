defmodule MultiAgent.Server do
  @moduledoc false

  alias MultiAgent.{Callback, Worker, Req}

  import Worker, only: [inc: 1, new_state: 1]

  import Enum, only: [uniq: 1]
  import Map, only: [delete: 2]
  import Req, only: [fetch: 2, handle: 2]

  use GenServer


  ##
  ## GenServer callbacks
  ##

  def init({funs, timeout}) do
    with keys = Keyword.keys( funs),
         [] <- keys--uniq( keys), #check for dups
         {:ok, results} <- Callback.safe_run( funs, timeout) do

      map = for {key, s} <- results, into: %{} do
              {key, new_state {:state, s}}
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
  ## Map functions
  ##

  defp has_key?( map, key) do
    case fetch map, key do
      {:ok, _} -> true
      _ -> false
    end
  end

  ## IMMEDIATE REPLY

  def handle_call(:keys,_from, map) do
    keys = for key <- Map.keys( map),
               has_key?( map, key), do: key

    {:reply, keys, map}
  end

  def handle_call({:has_key?, key},_from, map) do
    {:reply, has_key?( map, key), map}
  end

  def handle_call({:!, {:fetch, key}},_from, map) do
    {:reply, fetch( map, key), map}
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
  ## Handle Reqs
  ##

  # init is a Map.put analog
  def handle_call({:init, key, fun, opts}, from, map) do

    if Map.has_key? map, key do
      {:reply, {:error, {key, :already_exists}}, map}
    else
      timeout = opts[:timeout] || 5000

      fun = fn [_state] ->
        task = Task.async fn -> Callback.run fun end
        res = Task.yield( task, timeout)
           || Task.shutdown( task, :brutal_kill)

        case res do
          {:ok, state} -> {{:ok, state}, [state]}
          nil ->
            {{:error, :timeout}, :id}
          exit ->
            {{:error, exit}, :id}
        end
      end

      late_call = opts[:late_call] || false
      threads_num = opts[:max_threads] || 5
      map = put_in map[key], {nil, late_call, threads_num}

      handle %Req{action: :get_and_update,
                  from: from,
                  data: {fun, [key]}}, map
    end
  end

  def handle_call( req, from, map) do
    handle %{req | :from => from}, map
  end

  def handle_cast( req, map) do
    handle req, map
  end


  ##
  ## Info
  ##

  defp update_or_cast?( act) when is_atom(act), do: act not in [:get, :done, :id]
  defp update_or_cast?({:!, msg}), do: update_or_cast? msg
  defp update_or_cast?({act,_,_,_}), do: update_or_cast? act
  defp update_or_cast?({act,_}), do: update_or_cast? act


  defp count(_key, []), do: 0
  defp count( key, [req | reqs]) do
    num = Req.lookup key, req
    if num == :update, do: :update,
                       else: num + count(key, reqs)
  end


  # `get`-callback was executed on server
  def handle_info({:done_on_server, key}, map) do
    map = case map do
      %{^key => {:pid, worker}} ->
        send worker, {:!, :done_on_server}
        map

      %{^key => {nil, _, 4}} ->
        delete map, key

      %{^key => state} ->
        %{map | key => inc(state)}

      _ -> map
    end

    {:noreply, map}
  end


  # worker asks to exit
  def handle_info({worker, :mayidie?}, map) do
    {:messages, queue} = Process.info worker, :messages
    {:messages, future} = Process.info self(), :messages
    {:dictionary, dict} = Process.info worker, :dictionary

    key = dict[:'$key']

    # msgs could come during a small delay between
    # this call happend and :mayidie? was sent.
    # Server queue could contain requests that will
    # recreate worker, so why let him die?
    with true <- dict[:'$max_threads'] > length(queue),
         false <- Enum.any?( queue, &update_or_cast?/1),
         num = count(key, future),
         false <- num == :update,
         true <- dict[:'$max_threads'] > num + length(queue) do

      late_call = dict[:'$late_call']
      state = dict[:'$state']

      for {:get, fun, from,_expires} <- queue do
        server = self()
        Task.start_link fn ->
          GenServer.reply from, Callback.run( fun, [state])
          send server, {:done_on_server, key}
        end
      end

      send worker, :die!

      unless Keyword.has_key? dict, :'$state' do
        {:noreply, delete( map, key)} #GC
      else
        max_t = dict[:'$max_threads']
        tuple = {{:state,state}, late_call, max_t-length(queue)}

        {:noreply, %{map | key => tuple}}
      end
    else
      _ ->
        send worker, :continue
        {:noreply, map}
    end
  end

  def handle_info( msg, state) do
    super msg, state
  end


  def code_change(_old, state, fun) do
    {:ok, Callback.run( fun, [state])}
  end

end

defmodule MultiAgent.Server do
  @moduledoc false

  alias MultiAgent.{Callback, Worker, Transaction, Req}

  import Worker, only: [inc: 1, dec: 1]
  import Callback, only: [parse: 1]

  import Enum, only: [uniq: 1]
  import Map, only: [put: 3, delete: 2]

  use GenServer


  defp key({:!, msg}), do: key msg
  defp key( msg) do
    {key,_} = elem msg, 1
    key
  end


  defp fetch( map, key) do
    case map do
      %{^key => {:pid, worker}} ->
        {:dictionary, dict} =
          Process.info worker, :dictionary
        {:ok, dict[:'$state']}

      %{^key => {{:state, state},_,_}} -> {:ok, state}

      _ -> :error
    end
  end

  # extract state, returning nil if it's not there
  defp get( map, key) do
    case fetch( map, key) do
      {:ok, state} -> state
      _ -> nil
    end
  end


  ##
  ## GenServer callbacks
  ##

  def init({funs, timeout}) do
    with keys = Keyword.keys( funs),
         [] <- keys--uniq( keys),
         {:ok, results} <- Callback.safe_run( funs, timeout) do

      Enum.reduce results, {:ok, %{}}, fn {key,s}, {:ok, map} ->
        {:ok, put( map, key, Worker.new_state {:state,s})}
      end
    else
      dup ->
        {:stop, for key <- dup do {key, :already_exists} end}
      {:error, reason} ->
        {:stop, reason}
    end
  end


  #
  # Analog of Map functions
  #

  defp has_key?( map, key) do
    case fetch map, key do
      {:ok, _} -> true
      _ -> false
    end
  end


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
    res = for key <- keys,
              has_key?( map, key),
              into: %{} do

            {key, get( map, key)}
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


  # init is a Map.put analog
  def handle_call(%Req{:action => :init}=req, from, map) do
    {key, fun, opts} = req.data

    if Map.has_key? map, key do
      {:reply, {:error, {key, :already_exists}}, map}
    else
      fun = fn _ -> Callback.run( fun) end
      req = %Req{:action => :update,
                 :data => {key, fun},
                 :expires => req.expires,
                 :from => from}

      late_call = opts[:late_call] || false
      threads_num = opts[:max_threads] || 5
      map = put map, key, {nil, late_call, threads_num}

      Req.handle req, map
    end
  end

  # transaction
  def handle_call(%Req{}=req, from, map) do
    Req.handle %{req | :from => from}
  end

  def handle_call(%Req{:data => {_f,keys}}=req, from, map) when is_list( keys) do
    Req.handle %{req | :from => from}
  end

  def handle_call({_act, {_fun,keys}}=msg, from, map) when is_list( keys) do
    {:noreply, Transaction.run( form( msg, from), map)}
  end

  def handle_call({:!, {_, {_,keys}}}=msg, from, map) when is_list( keys) do
    {:noreply, Transaction.run( form( msg, from), map)}
  end

  # execute immediately
  def handle_call( msg, from, map) do
    handle form( msg, from), map
  end


  def handle_cast({_,{_,keys}}=msg, map) when is_list( keys) do
    {:noreply, Transaction.run( msg, map)}
  end

  def handle_cast({_,{_,keys}}=msg, map) when is_list( keys) do
    {:noreply, Transaction.run( msg, map)}
  end

  def handle_cast( msg, map), do: handle msg, map


  defp changing_state?( key, {:'$gen_cast', msg}), do: changing_state? key, msg
  defp changing_state?( key, {:'$gen_call', _, msg}), do: changing_state? key, msg

  defp changing_state?( key, {act, {_,[key|_]}}), do: changing_state? act
  defp changing_state?( key, {act, {fun,[_|keys]}}), do: changing_state? key, {act, {fun,keys}}
  defp changing_state?( key, {act, {key,_}}), do: changing_state? act
  defp changing_state?( key, {act, {key,_},_}), do: changing_state? act
  defp changing_state?(_key,_msg), do: false


  defp changing_state?({action, :!}), do: changing_state? action

  defp changing_state?({:!, msg}), do: changing_state? msg
  defp changing_state?({action,_,_,_}), do: changing_state? action
  defp changing_state?({action,_}), do: changing_state? action

  defp changing_state?( act), do: act in [:get, :get_and_update, :update, :cast, :done_on_server]


  # `get`-callback was executed on server
  def handle_info({:done_on_server, key}, map) do
    map = case map do
            %{^key => {:pid, worker}} ->
              send worker, {:!, :done_on_server}
              map

            %{^key => {nil, _, 4}} ->
              delete map, key

            %{^key => {state, late_call, t_num}} ->
              %{map | key => {state, late_call, inc(t_num)}}

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


    if dict[:'$max_threads'] > length( queue)
    && not Enum.any?( queue, &changing_state?/1)
    && not Enum.any?( future, &changing_state?( key, &1)) do

      state = dict[:'$state']
      late_call = dict[:'$late_call']

      for {:get, fun, from,_expires} <- queue do
        server = self()
        Task.start_link fn ->
          GenServer.reply from, Callback.run( fun, [state])
          send server, {:done_on_server, key}
        end
      end

      send worker, :die!

      case state do
        {nil,_,_} ->
          {:noreply, delete( map, key)}

        _ ->
          max_t = dict[:'$max_threads']
          tuple = {state, late_call, max_t - length(queue)}

          {:noreply, %{map | key => tuple}}
      end
    else
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

defmodule MultiAgent.Server do
  @moduledoc false

  @compile {:inline, new_state: 0, new_state: 1}

  alias MultiAgent.{Callback, Worker, Transaction}

  import Worker, only: [inc: 1, dec: 1]
  import Callback, only: [parse: 1]

  import Enum, only: [uniq: 1]
  import Map, only: [put: 3, has_key?: 2, delete: 2, get: 3]

  use GenServer


  defp new_state( state \\ nil), do: {state, false, 5}


  defp callback(:get, transaction, state) do
    send t, {self(), state}
  end

  defp callback(:get_and_update, transaction, state) do
    callback(:get, transaction, state)
    callback(:update, transaction, state)
  end

  defp callback(:update, transaction, state) do
    receive do
      {:state, state} -> {nil, state}
      :id -> {nil, state}
      :drop -> :pop
    end
  end



  defp run_transaction( msg, map) do
    {{known, workers}, map} = Transaction.prepair msg, map

    case elem msg, 0 do
      {:get, :!} ->
        t = Task.start_link( Transaction, :flow, [msg, {known, workers}])

      {:get_and_update | :update | cast, :!} ->
        callback = 
          :get ->
        callback = fn state ->
          send t, {self(), state}
          receive do
            {:state, state} -> {nil, state}
            :id -> {nil, state}
            :drop -> :pop
          end
        end
    

    Enum.reduce workers, %{}, fn worker, map ->
      msg = if act in [:cast, :cast!] do
              {act, key, &Transaction.callback( act, t, &1)}
            else
              {act, key, &Transaction.callback( act, t, &1), :infinity}
        end

        :get_and_update | :update | cast ->
          callback = fn state ->
            send t, {self(), state}
            receive do
              {:state, state} -> {nil, state}
              :id -> {nil, state}
              :drop -> :pop
            end
          end
        {:cast, :!} -> :ignore

        :get ->
           handle msg, 
        :get_and_update ->
        :update ->
        :cast ->
      end

      def callback( :get,_tr, state), do: state
      def callback( act, tr, state) when act in [:get_and_update,
                                                 :get_and_update!] do
      end

      def callback( act, tr, state) when act in [:update, :update!] do
        send tr, {self(), state}
        receive do
          {:state, state} -> state
        end
      end

      handle( msg act,)
    end
  end


  # convert message used on server
  # to the one expected on worker
  defp format({{:cast,:!}, {_key,fun}}), do: {:!, {:cast, fun}}
  defp format({:cast, {_key,fun}}), do: {:cast, fun}
  defp format({{act,:!}, {_key,fun}, from, exp}), do: {:!, {act, fun, from, exp}}
  defp format({act, {_key,fun}, from, exp}), do: {act, fun, from, exp}

  # →
  defp handle({{:get,:!}, {key,fun}, from}, map) do
    state = case map do
              %{^key => {:pid, worker}} ->
                Process.info( worker, :dictionary)[:'$state']
              %{^key => {state,_,_}} -> state
              _ -> nil
            end
            |> parse()

    Task.start_link( fn ->
      GenServer.reply( from, Callback.run( fun, [state]))
    end)

    {:noreply, map}
  end

  defp handle({:get, {key,f}, from, _}=msg, map) do
    case get map, key, new_state do

      {:pid, worker} ->
        send worker, format msg
        {:noreply, map}

      {state, late_call, t_num} when t_num > 1 ->

        server = self
        Task.start_link( fn ->
          GenServer.reply from, Callback.run( f, [parse state])

          unless t_num == :infinity do
            send server, {:done_on_server, key}
          end
        end)

        {:noreply, put( map, key, {state, late_call, dec(t_num)})}

      tuple -> # max_threads forbids to spawn more Tasks
        worker = spawn_link( Worker, :loop, [self(), key, tuple])

        send worker, format msg
        {:noreply, put( map, key, {:pid, worker})}
    end
  end

  defp handle( msg, map) do
    {key,_} = elem msg, 1
    msg = format msg

    case get map, key, new_state do
      {:pid, worker} ->
        send worker, msg
        {:noreply, map}

      tuple ->
        worker = spawn_link( Worker, :loop, [self, key, tuple])
        send worker, msg
        {:noreply, put( map, key, {:pid, worker})}
    end
  end

  ##
  ## GenServer callbacks
  ##

  def init({funs, timeout}) do
    with keys = Keyword.keys funs,
         [] <- keys--uniq( keys),
         {:ok, results} <- Callback.safe_run( funs, timeout) do

      Enum.reduce( results, {:ok, %{}}, fn {key,s}, {:ok, map} ->
        {:ok, put( map, key, new_state {:state,s})}
      end)
    else
      dup ->
        {:stop, for key <- dup do {key, :already_exists} end}
      {:error, reason} ->
        {:stop, reason}
    end
  end


  # init is a Map.put analog
  def handle_call({:init, {key,f,opts}, expires}, from, map) do
    if Map.has_key?( map, key) do
      {:reply, {:error, {key, :already_exists}}, map}
    else
      fun = fn _ -> Callback.run( f) end
      late_call = opts[:late_call] || false
      threads_num = opts[:max_threads] || 5
      map = put( map, key, {nil, late_call, threads_num})

      handle {:update, {key,fun}, from, expires}, map
    end
  end

  # transactions
  def handle_call({act, {fun,keys}}=msg, from, map) when is_list( keys) do
    msg = {act, {fun,keys}, from}
    {:noreply, run_transaction( msg, map)}
  end

  # execute immediately
  def handle_call({{:get,:!}, data}, from, map) do
    handle {{:get,:!}, data, from}, map
  end


  def handle_call({act, data, exp}=msg, from, map) do
    handle {act, data, from, exp}, map
  end

  def handle_call(:keys, from, map) do
    keys = keys( map)
           |> Enum.filter(& not match? {nil,_,_}, map[&1])
    {:reply, keys, map}
  end

  def handle_call( msg, from, map), do: super msg, from, map


  def handle_cast({_,{_,keys}}=msg, map) when is_list( keys) do
    {:noreply, run_transaction( msg, map)}
  end

  def handle_cast( msg, map), do: handle msg, map
  def handle_cast( msg, state), do: super msg, state


#  defguardp is_state_changing( act) when act in [:get, :get_and_update, :update, :cast, :done_on_server]

  defp changing_state?( key, {:'$gen_cast', msg}), do: changing_state? key, msg
  defp changing_state?( key, {:'$gen_call', _, msg}), do: changing_state? key, msg

  defp changing_state?( key, {act, {_,keys}}) when key in keys, do: changing_state? act
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

            %{^key => {nil, late_call, 4}} ->
              delete map, key

            %{^key => {state, late_call, t_num}} ->
              %{map | key => {state, late_call, inc(t_num)}}

            _ -> map
          end

    {:noreply, map}
  end

  # worker asks to exit
  def handle_info({worker, :suicide?}, map) do
    queue = Process.info( worker, :messages)
    future = Process.info( self(), :messages)
    dict = Process.info( worker, :dictionary)

    key = dict[:'$key']


    if dict[:'$max_threads'] > length( queue)
    && not Enum.any?( queue, &changing_state?/1)
    && not Enum.any?( future, &changing_state?( key, &1)) do

      state = dict[:'$state']
      late_call = dict[:'$late_call']

      for {:get, fun, from, expires} <- queue do
        tuple = {state, late_call, :infinity}
        handle {:get, {key,fun}, from, expires}, key, tuple
      end

      send worker, :die!

      case state do
        {nil,_,_} ->
          {:noreply, delete map, key}
        _ ->
          max_threads = dict[:'$max_threads']
          tuple = {state, late_call, max_threads-length( queue)}
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

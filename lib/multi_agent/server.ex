defmodule MultiAgent.Server do
  @moduledoc false

  @compile {:inline, new_state: 0, new_state: 1}

  alias MultiAgent.{Callback, Worker, Transaction}

  import Worker, only: [inc: 1, dec: 1]
  import Callback, only: [parse: 1]

  import Enum, only: [uniq: 1]
  import Map, only: [put: 3, has_key?: 2]

  use GenServer


  defp new_state( state \\ nil), do: {state, false, 5}


  def init({funs, timeout}) do
    with keys = Keyword.keys funs,
         [] <- keys--uniq keys,
         {:ok, results} <- Callback.safe_run funs, timeout do

      Enum.reduce( results, {:ok, %{}}, fn {key,s}, {:ok, map} ->
        {:ok, put( map, key, new_state({:state,s}))}
      end)
    else
      dup ->
        {:stop, for key <- dup do {key, :already_exists} end}
      {:error, reason} ->
        {:stop, reason}
    end
  end


  defp run_transaction( msg, map) do
    {{known, workers}, map} = Transaction.prepair( msg, map)

    t = Task.start_link( Transaction, :flow, [known, msg, from])

    Enum.reduce workers, %{}, fn worker, map ->
      msg = if act in [:cast, :cast!] do
              {act, key, &Transaction.callback( act, t, &1)}
            else
              {act, key, &Transaction.callback( act, t, &1), :infinity}
            end
      handle( msg act,)
    end
  end


  # →
  defp handle( msg, key, map) do
    state = Map.get( map, key, new_state())
    {:noreply, %{map | key => handle( msg, state)}}
  end

  # :get — can create more threads (t_num > 1),
  # so, spawn tasks directly from server.
  defp handle({:get, {key,f}, from, _}, {s, late_call, t_num}) when t_num > 1 do
    server = self()
    Task.start_link( fn ->
      state = parse( s)
      GenServer.reply( from, Callback.run( f, [state]))

      unless t_num == :infinity do
        send server, {:done!, key}
      end
    end)

    {state, late_call, dec(t_num)}
  end

  # handle out of order calls
  defp handle({{action,:!}, kf, from, expires}, tuple) do
    handle({:!, {action, kf, from, expires}}, tuple)
  end

  # forward message to existing worker
  defp handle( msg, {:pid, worker}) do
    {:pid, send( worker, msg) && worker}
  end

  # create worker and send him the message
  defp handle({_act, {key,_fun},_from,_expires}=msg, tuple) do
    worker = spawn_link( Worker, :loop, [self(), key, tuple])
    handle( msg, {:pid, worker})
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

      handle_call({:update, {key,fun}, expires}, from, map)
    end
  end

  # transactions
  def handle_call({act, fun, keys}=msg, from, map) when is_list( keys) do
    msg = {act, fun, keys, from}
    {:noreply, run_transaction( msg, from, map)}
  end

  # execute immediately
  def handle_call({{:get, :!}, {key,f}}, from, map) do
    state = case map do
              %{^key => {:pid, worker}} ->
                Process.info( worker, :dictionary)[:'$state']
              %{^key => {state,_,_}} -> state
              _ -> nil
            end
            |> parse()

    Task.start_link( fn ->
      GenServer.reply( from, Callback.run( f, [state]))
    end)

    {:noreply, map}
  end


  def handle_call({act, {key,f}, exp}=msg, from, map) do
    msg = {act, {key,f}, from, exp}
    handle( msg, key, map)
  end


  def handle_call(:keys, from, map) do
    keys = keys( map)
           |> Enum.filter(& not match? {nil,_,_}, map[&1])
    {:reply, keys, map}
  end

  def handle_call( msg, from, state) do
    super( msg, from, state)
  end



  def handle_cast({act, {fun, keys}}=msg, map) when is_list( keys) do
    {:noreply, run_transaction( act, fun, keys, map)}
  end

  def handle_cast({act, {key,fun}}=msg, map) do
    handle( act, key, fun, :infinity, map)
  end

  def handle_cast( msg, state) do
    super( msg, state)
  end


  # transaction call
  defp update?( key, {:'$gen_cast', msg}), do: update? key, msg
  defp update?( key, {:'$gen_call', _, msg}), do: update? key, msg

  defp update?( key, {act, {fun,keys}}) when is_list( keys) do
    update? action && key in keys
  end
  defp update?( key, {act, {key,_},_}), do: update? action
  defp update?( key, {act, {key,_}}), do: update? action
  defp update?(_key, _), do: false


  defp update?({action, :!}), do: update? action

  defp update?({:!, msg}), do: update? msg
  defp update?({action,_,_,_}), do: update? action
  defp update?({action,_}), do: update? action

  defp update?( action) do
    action in [:get, :get_and_update, :cast, :done!]
  end


  def handle_info({:done!, key}, map) do
    case map do
      %{^key => {:pid, worker}} ->
        send worker, {:!, :done!} #%)

      %{^key => {state, late_call, t_num}} ->
        map = %{map | key => {state, late_call, inc(t_num)}}

      _ ->
        :ignore
    end
    {:noreply, map}
  end


  def handle_info({worker, :suicide?}, map) do
    queue = Process.info( worker, :messages)
    dict = Process.info( worker, :dictionary)
    key = dict[:'$key']

    if dict[:'$max_threads'] > length( queue)
    && not Enum.any?( queue, &update?/1)
    && not Enum.any?( Process.info( self(), :messages),
                      &update?( key, &1)) do

      state = dict[:'$state']
      late_call = dict[:'$late_call']

      for message <- queue do
        case message do
          {:get, fun, from, expires} ->
            tuple = {state, late_call, :infinity}
            handle({:get, {key,fun}, from, expires}, tuple)
          _ -> :ignore
        end
      end

      send worker, :die!

      max_threads = dict[:'$max_threads']
      tuple = {state, late_call, max_threads-length( queue)}

      {:noreply, %{map | key => tuple}}
    else
      send worker, :continue
      {:noreply, map}
    end
  end

  def handle_info( msg, state) do
    super( msg, state)
  end


  def code_change(_old, state, fun) do
    {:ok, Callback.run( fun, [state])}
  end

end

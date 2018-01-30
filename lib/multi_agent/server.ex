defmodule MultiAgent.Server do
  @moduledoc false

  @compile {:inline, new_state: 1, new_state: 0}

  alias MultiAgent.{Callback, Worker, Transaction}

  import Worker, only: [inc: 1, dec: 1]
  import Callback, only: [parse: 1]

  import Enum, only: [uniq: 1]
  import Map, only: [put: 3, has_key?: 2]

  use GenServer


  defp new_state( state \\ nil), do: {state, false, 5}


  def init({funs, timeout}) do
    with keys = Keyword.keys funs,
         [] <- keys--uniq( keys),
         {:ok, results} <- Callback.safe_run( funs, timeout) do

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


  # →
  defp handle( msg, key, map) do
    state = Map.get( map, key, new_state())
    {:noreply, %{map | key => handle( msg, state)}}
  end

  # :get — can create more threads (t_num > 1),
  # so, spawn tasks directly from server.
  defp handle({:get, {key,f}, from, _}, {s, call_exp, t_num}) when t_num > 1 do
    server = self()
    Task.start_link( fn ->
      state = parse( s)
      GenServer.reply( from, Callback.run( f, [state]))

      unless t_num == :infinity do
        send server, {:done!, key}
      end
    end)

    {state, call_exp, dec(t_num)}
  end

  # handle out of order calls
  defp handle({{action,:!}, kf, from, exp}, tuple) do
    handle({:!, {action, kf, from, exp}}, tuple)
  end

  # forward message to existing worker
  defp handle( msg, {:pid, worker}) do
    {:pid, send( worker, msg) && worker}
  end

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
    {:noreply, Transaction.run( msg, map)}
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



  def handle_cast({:cast, {_fun, keys}}=msg, map) when is_list( keys) do
    {:noreply, Transaction.run( msg, map)}
  end

  def handle_cast({:cast, {key,_}}=msg, map) do
    handle( msg, key, map)
  end

  def handle_cast( msg, state) do
    super( msg, state)
  end


  defp update?(key, {:'$gen_cast', {:cast, {key,_}}}), do: true
  defp update?(key, {:'$gen_call', _, {{action, :!}, kf, expires}}) do
    update?(key, {:'$gen_call', _, {action, kf, expires}})
  end
  defp update?(key, {:'$gen_call', _, {action, {key,_},_expires}}) do
    action in [:get_and_update, :update]
  end
  defp update?(_key,_msg), do: false

  defp update?({:!, message}), do: update?( message)
  defp update?({action,_,_,_}), do: action in [:get_and_update, :update]
  defp update?({:cast,_}), do: true
#  defp update?(:done), do: false
  defp update?(:done!), do: true
  defp update?(m), do: IO.inspect( m); false


  def handle_info({:done!, key}, map) do
    case map do
      %{^key => {:pid, worker}} ->
        send worker, :done!

      %{^key => {state, call_exp, t_num}} ->
        map = %{map | key => {state, call_exp, inc(t_num)}}

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
      max_threads = dict[:'$max_threads']

      tuple = {state, late_call, max_threads}

      for message <- queue do
        case message do
          {:get, fun, from} ->
            handle({:get, {key, fun}, from}, tuple)
          _ -> :ignore
        end
      end

      send worker, :die!

      map = %{map | key => {state, late_call, max_threads-length( queue)}}

      {:noreply, map}
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

defmodule MultiAgent.Server do
  @moduledoc false

  alias MultiAgent.{Callback, Worker, Transaction}

  import Worker, only: [inc: 1, dec: 1]
  import Callback, only: [parse: 1, call?: 2]

  use GenServer


  # Common helpers for init
  defp dup_check( funs) do
    keys = Keyword.keys funs
    case keys -- Enum.dedup( keys) do
      [] -> {:ok, funs}
      ks -> {:error, Enum.map( ks, & {&1, :already_exists})}
    end
  end

  # ->
  def init({funs, timeout, extra_state}) do
    with {:ok, funs} <- dup_check( funs),
         {:ok, results} <- Callback.safe_run( funs, timeout) do

      map = Enum.reduce( results, %{}, fn {key,state}, map ->
        Map.put_new( map, key, {{:state, state}, false, 5})
      end)

      {:ok, {map,extra_state}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end


  # :get — can create more threads.
  # So, spawn tasks directly from server
  defp handle({:get, {key, fun}, from}, {state, call_expired, t_num}) when t_num > 1 do
    server = self()
    Task.start_link( fn ->
      state = parse( state)
      GenServer.reply( from, Callback.run( fun, [state]))

      unless t_num == :infinity do
        send server, {:done, key}
      end
    end)

    {state, call_expired, dec( t_num)}
  end

  defp handle({action, {key,fun}, from}=msg, tuple) do
    pid = spawn_link( Worker, :loop, [self(), key, tuple])
    msg = case action do
            {action, :!} ->
              {:!, {action, {key,fun}, from}}
            _ -> msg
          end

    {:pid, send( pid, msg) && pid} # forward
  end


  def handle_call({:init, {key,fun,opts}, until}, from, {map,extra}=g_state) do
    if Map.has_key?( map, key) do
      {:reply, {:error, {key, :already_exists}}, g_state}
    else
      fun = fn _ -> Callback.run( fun) end
      call_expired = opts[:call_expired] || false
      t_num = opts[:max_threads] || 5
      map = Map.put( map, key, {nil, call_expired, t_num})

      handle_call({:update, {key,fun}, until}, from, {map,extra})
    end
  end

  # transactions
  def handle_call({action, fun, keys}=msg, from, {map,extra}) when is_list( keys) do
    {known, map} = Transaction.prepair( msg, from, map)

    msg = case action do
            {action, :!} -> {action, fun, keys}
            _ -> msg
          end

    Task.start_link( Transaction, :loop, [known, msg, from])

    {:noreply, {map,extra}}
  end


  # handle "call_expired"-related stuff; "no key" case and forward if worker exists
  def handle_call({action, {key,_}=kf, until}, from, {map,extra}=g_state) do
    msg = {action, kf, from}

    case map do
      %{^key => {:pid, worker}} -> # forward to corresp. worker
        call_expired
          = Process.info( worker, :dictionary)[:'$call_expired']
        if call?( until, call_expired) do
          send worker, msg
        end
        {:noreply, g_state}

      %{^key => {_,call_expired,_}=state} ->
        if call?( until, call_expired) do
          map = %{map | key => handle( msg, state)}
          {:noreply, {map,extra}}
        else
          {:noreply, g_state}
        end

      _ -> # don't know anything about given key
        temp_state = handle( msg, {nil, false, 5})
        map = Map.put( map, key, temp_state)
        {:noreply, {map,extra}}
    end
  end

  # execute immediately
  def handle_call({{:get, :!}, {key, fun}}, from, {map,_}=g_state) do
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

    {:noreply, g_state}
  end

  def handle_call( msg, from, state) do
    super( msg, from, state)
  end



  def handle_cast({:cast, {_fun, keys}}, _state) when is_list( keys) do
    {:stop, :TBD}
  end

  def handle_cast({:cast, {key,_}}=msg, {map,extra}=g_state) do
    case map do
      %{^key => {:pid, worker}} -> # forward to corresp. worker
        send worker, msg
        {:noreply, g_state}

      %{^key => state} ->
        {:noreply, {%{map | key => handle( msg, state)}, extra}}

      _ -> # don't know anything about given key
        temp_state = handle( msg, {nil, false, 5})
        map = Map.put( map, key, temp_state)
        {:noreply, {map,extra}}
    end
  end

  def handle_cast( msg, state) do
    super( msg, state)
  end


  defp update?(key, {:'$gen_cast', {:cast, {key,_}}}), do: true
  defp update?(key, {:'$gen_call', _, {action, {key,_}, _until}}) do
    action in [:get_and_update, :update]
  end
  defp update?(_key,_msg), do: false

  defp update?({:!, message}), do: update?( message)
  defp update?({action,_,_}), do: action in [:get_and_update, :update]
  defp update?({:cast,_}), do: true
  defp update?(:done), do: false
  defp update?(:done!), do: true
  defp update?(m), do: IO.inspect( m); false


  def handle_info({:done, key}, {map,extra}=g_state) do
    case map do
      %{^key => {:pid, pid}} ->
        send( pid, :done!)
        {:noreply, g_state}
      %{^key => {state, call_exp, t_num}} ->
        map = %{map | key => {state, call_exp, inc( t_num)}}
        {:noreply, {map, extra}}
      _ ->
        {:noreply, g_state}
    end
  end


  def handle_info({worker, :suicide?}, {map,extra}=g_state) do
    queue = Process.info( worker, :messages)
    dict = Process.info( worker, :dictionary)
    key = dict[:'$key']

    if dict[:'$max_threads'] > length( queue)
    && not Enum.any?( queue, &update?/1)
    && not Enum.any?( Process.info( self(), :messages),
                      &update?( key, &1)) do

      state = dict[:'$state']
      call_expired = dict[:'$call_expired']
      max_threads = dict[:'$max_threads']

      tuple = {state, call_expired, max_threads}

      for message <- queue do
        case message do
          {:get, fun, from} ->
            handle({:get, {key, fun}, from}, tuple)
          _ -> :ignore
        end
      end

      send worker, :die!

      map = %{map | key => {state, call_expired, max_threads-length( queue)}}

      {:noreply, {map,extra}}
    else
      send worker, :continue
      {:noreply, g_state}
    end
  end

  def handle_info( msg, state) do
    super( msg, state)
  end


  def code_change(_old, state, fun) do
    {:ok, Callback.run( fun, [state])}
  end

end

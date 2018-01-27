defmodule MultiAgent.Server do
  @moduledoc false

  alias MultiAgent.{Callback, Worker}

  use GenServer



  # Common helpers for init
  defp dup_check( funs) do
    keys = Keyword.keys funs
    case keys -- Enum.dedup( keys) do
      [] -> {:ok, funs}
      ks -> {:error, Enum.map( ks, & {&1, :already_exists})}
    end
  end


  def init({funs, :infinity, extra_state}) do
    init( funs, :infinity, extra_state)
  end

  def init({funs, timeout, extra_state}) do
    init( funs, timeout-10, extra_state)
  end


  # ->
  defp init( funs, timeout, extra_state) do
    with {:ok, funs} <- dup_check( funs),
         {:ok, results} <- Callback.safe_run( funs, timeout) do

      map = Enum.reduce( results, %{}, fn {key,state}, map ->
        opts = []
        Map.put_new( map, key, {{:state, state}, opts, opts[:max_threads]})
      end)

      {:ok, {map,extra_state}}
    else
      {:error, err} -> {:stop, err}
    end
  end


  def handle_call({:init, {key, fun, opts}, until}, from, {map, extra}=g_state) do
    case state do
      %{^key => _} ->
        {:reply, {:error, {key, :already_exists}}, g_state}
      _ ->
        pid = spawn_link( Worker, :loop, [self(), opts]])
        map = Map.put_new( map, key, {:pid, pid})
        send pid, {:update, fun, until}
        {:noreply, {map,extra}}
    end
  end


  def handle_call({:get, _fun, keys}, _from, _state) when is_list( keys) do
    {:stop, :TBD}
  end

  def handle_call({:get!, _fun, keys}, _from, _state) when is_list( keys) do
    {:stop, :TBD}
  end

  def handle_call({:get_and_update, _fun, keys}, _from, _state) when is_list( keys) do
    {:stop, :TBD}
  end

  def handle_call({:update, _fun, keys}, _from, _state) when is_list( keys) do
    {:stop, :TBD}
  end


  def handle_call({:get, {key,fun}, until}=tuple, from, {map, extra}=g_state) do
    case map do
      %{^key => {:pid, pid}} ->
        send pid, {tuple, from}
        {:noreply, g_state}

      %{^key => {state, opts, threads_num}} ->
        if Worker.call? until, opts[:call_expired] do
          state = if threads_num > 1 do
                    server = self()
                    Task.start_link( fn ->
                      Callback.call( fun, state, from)
                      send server, {:done, key}
                    end)
                    {state, opts, threads_num-1}
                  else
                    pid = spawn_link( Worker, :loop, [self(), state, opts, 1])
                    send pid, {tuple, from}
                    {:pid, pid}
                  end

          {:noreply, {%{map | key => state}, extra}}
        else
          {:noreply, g_state}
        end

      _ -> # no such state
        temp_state = {nil, [call_expired: false, max_threads: 2], 2}
        map = Map.put_new( map, key, temp_state)
        handle_call( tuple, from, g_state)
    end
  end

  # execute immediately
  def handle_call({:get!, {key, fun}, until}, from, g_state) do
    state = case map do
              %{^key => {:pid, pid}} ->
                Process.info(:dictionary)[:state]
              _ ->
                nil
            end

    Task.start_link( Callback, :call, [fun, state, from])
    {:noreply, g_state}
  end

  def handle_call({action, {key, fun}, timeout}=tuple, from, {map, extra}) do
    case map do
      %{^key => {:pid, pid}} ->
        send pid, tuple
        {:noreply, {map, extra}}

      %{^key => {state, opts, threads_num}=tuple} ->

        {state, pid} = find_or_init( state, key)

    send pid, {{action, from, {key, fun}}, timeout}
    {:noreply, state}
  end

  def handle_call( msg, from, state) do
    super( msg, from, state)
  end



  def handle_cast({:update, {_fun, keys}}, _state) when is_list( keys) do
    {:stop, :TBD}
  end

  def handle_cast({:update, {key, fun}}, state) do
    {state, pid} = find_or_init( state, key)

    send pid, {:cast, {key, fun}}
    {:noreply, state}
  end

  def handle_cast( msg, state) do
    super( msg, state)
  end


  def handle_info({:pop, key}, state) do
    with {:ok, pid} <- find_process( state, key),
         {:dictionary, dict} <- Process.info(:dictionary, pid)
         false <- List.keymember?( dict, key, 0) do

      {:noreply, forget( state, key)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info( msg, state) do
    super( msg, state)
  end


  def code_change(_old, state, fun) do
    {:ok, Callback.run( fun, [state])}
  end

end

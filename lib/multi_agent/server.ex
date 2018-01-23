defmodule MultiAgent.Server do
  @moduledoc false

  alias MultiAgent.Callback

  use GenServer

  # Common helpers for init
  defp prepair( funs) do
    keys = Keyword.keys funs
    case keys -- Enum.dedup( keys) do
      []  -> {:ok, funs}
      ks  -> {:error, Enum.map( ks, & {&1, :already_exists})}
    end
  end


  defp loop(_key, state, opts) do
    receive do
      {:get, from, {key, fun}} ->
        GenServer.reply( from, Callback.run( fun, [state]))
        loop( key, state, opts)

      {:get_and_update, from, {key, fun}} ->
        case Callback.run( fun, [state]) do
          {result, new_state} ->
            GenServer.reply( from, result)
            loop( key, new_state, opts)
          :pop ->
            IO.inspect(:TBD_get_and_update_pop)
            GenServer.reply( from, state)
            loop( key, nil, opts)
        end

      {:update, from, {key, fun}} ->
        new_state = Callback.run( fun, [state])
        GenServer.reply( from, :ok)
        loop( key, new_state, opts)

      {:cast, {key, fun}} ->
        loop( key, Callback.run( fun, [state]), opts)
    end
  end


  # return pid of process responsible for given key
  # — nil if no such key
  defp find_process( global_state, key) do
    if pid = global_state[ key] do
      {:ok, pid}
    else
      :error
    end
  end

  # register process
  defp add_process( global_state, pid, key) do
    Map.put_new( global_state, key, pid)
  end

  # initialize state: create new process or associate with existing
  # if already initialized — return error
  defp new_state( global_state, {key, state}, opts \\ []) do
    case find_process( global_state, key) do
      :error ->
        pid = spawn_link( fn ->
                            loop( key, state, opts)
                          end)
        {:ok, {add_process( global_state, pid, key), pid}}

      {:ok, _pid} -> {:error, {key, :already_exists}}
    end
  end


  def init({funs, async, timeout}) do
    with {:ok, funs} <- prepair( funs),
         {:ok, map} <- Callback.safe_run( funs, async, timeout-10),
         {:ok, global_state} <- Enum.reduce( map, %{}, & new_state( &2, &1)) do

      {:ok, global_state}
    else
      {:error, err} -> {:stop, err}
    end
  end


  defp find_or_init( state, key) do
    case find_process( state, key) do
      {:ok, pid} -> {state, pid}

       :error ->
          {:ok, {state, pid}} = new_state( state, {key, nil})
          {state, pid}
    end
  end


  def handle_call({:init, key, fun, callexpired}, from, state) do
    case new_state( state, {key, nil}, callexpired: callexpired) do
      {:ok, {state, _pid}} ->
        handle_call({:update, key, fn _ -> fun.() end}, from, state)

      {:error, err} -> {:stop, err}
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


  def handle_call({:get, key, fun}, from, global_state) do
    case find_process( global_state, key) do
      {:ok, pid} ->
        send pid, {:get, from, {key, fun}}
      :error ->
        Task.start_link fn ->
          GenServer.reply( from, Callback.run( fun, [nil]))
        end
    end

    {:noreply, global_state}
  end

  def handle_call({:get!, key, fun}, from, global_state) do
    case find_process( global_state, key) do
      {:ok, pid} ->
        send pid, {:get, from, {key, fun}}
      :error ->
        Task.start_link fn ->
          GenServer.reply( from, Callback.run( fun, [nil]))
        end
    end

    {:noreply, global_state}
  end

  def handle_call({action, key, fun}, from, state) when action in [:update, :get_and_update] do
    {state, pid} = find_or_init( state, key)

    send pid, {action, from, {key, fun}}
    {:noreply, state}
  end

  def handle_call( msg, from, state) do
    super( msg, from, state)
  end



  def handle_cast({:cast, _fun, keys}, _state) when is_list( keys) do
    {:stop, :TBD}
  end

  def handle_cast({:cast, key, fun}, state) do
    {state, pid} = find_or_init( state, key)

    send pid, {:cast, {key, fun}}
    {:noreply, state}
  end

  def handle_cast( msg, state) do
    super( msg, state)
  end


  def code_change(_old, state, fun) do
    {:ok, Callback.run( fun, [state])}
  end

end

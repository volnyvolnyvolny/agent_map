defmodule MultiAgent.Worker do
  @moduledoc false

  alias MultiAgent.Callback

  # return pid of process, responsible for given key
  # and nil if no such key
  def find( global_state, key) do
    if pid = global_state[ key] do
      {:ok, pid}
    else
      :error
    end
  end

  # move key from worker1 to worker2
  def move_key( global_state, worker1, worker2, key) do
    IO.inspect(:TBD_move_key)
    global_state
  end

  # add new worker
  def add_key( global_state, worker, key) do
    Map.put_new( global_state, key, worker)
  end

  # delete key
  def delete_key( worker, global_state, key) do
    send worker, {:delete, key}
    Map.delete( global_state, key)
  end


  defp execute( stack, opts) when is_list( stack) do
    case Enum.flat_map( stack, &execute(&1, opts)) do
      [{:delete, key}] -> Process.delete( key)
      [{:put, key, state}] -> Process.put( key, new_state)
      [] -> :donothing
    end
  end

  defp execute({:get, from, {key, fun}},_opts) do
    state = Process.get( key, nil)
    GenServer.reply( from, Callback.run( fun, [state]))
    []
  end

  defp execute({:get_and_update, from, {key, fun}}, opts) do
    state = Process.get( key, nil)
    case Callback.run( fun, [state]) do
      {result, state} ->
        GenServer.reply( from, result)
        [{:put, key, state}]
      :pop ->
        GenServer.reply( from, state)
        send opts[:gen_server], {:pop, key}
        [{:delete, key}]
    end
  end

  defp execute({:update, from, {key, fun}},_opts) do
    change = execute({:cast, {key, fun}})
    GenServer.reply( from, :ok)
    change
  end

  defp execute({:delete, from, key},_opts) do
    GenServer.reply( from, :ok)
    [{:delete, key}]
  end

  defp execute({:cast, {key, fun}},_opts) do
    state = Process.get( key, nil)
    [{:put, key, Callback.run( fun, [state])}]
  end


  # process holds keys and states in process dictionary
  # so they are accessible at any time outside of process
  # (via MultiAgent specifically.get!/2,4)
  def loop( stack, opts) do
    receive do
      {action, until} ->

        if opts[:callexpired]
        || until == :infinity
        || System.system_time < until do

          case action do
            {:get,_,_} -> loop([action|stack], opts)
            _action    -> execute([action|stack], opts)
          end
        end

      othermsg ->
        IO.inspect( othermsg)
        loop( stack, opts)
    end
  end

end

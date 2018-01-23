defmodule MultiAgent.Worker do
  @moduledoc false

  alias MultiAgent.Callback

  # return pid of process responsible for given key
  # and nil if no such key
  defp find( global_state, key) do
    if pid = global_state[ key] do
      {:ok, pid}
    else
      :error
    end
  end

  # add new worker
  defp assoc( global_state, pid, key) do
    Map.put_new( global_state, key, pid)
  end

  # remove key
  defp deassoc( global_state, key) do
    Map.delete( global_state, key)
  end


  defp execute( stack, opts) when is_list( actions) do
    case Enum.flat_map( stack, &execute(&1, opts)) end do
      [{:delete, key}] -> Process.delete( key)
      [{:put, key, state}] -> Process.put( key, new_state)
      [] -> :donothing
    end
  end

  defp execute({:get, from, {key, fun}},_opts) do
    state = Process.get( key, nil)
    # ref = make_ref()
    # case Process.get( key, ref) do
    #   ref ->
    #     raise {key, "Process does not know anything about given key!"}
    #   state ->
    #     result = Callback.run( fun, [state])
    #     GenServer.reply( from, result)
    # end
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

  defp execute({:cast, {key, fun}},_opts) do
    state = Process.get( key, nil)
    [{:put, key, Callback.run( fun, [state])}]
  end

  # process holds keys and states in process dictionary
  # so they are accessible at any time outside of process
  # (specifically via MultiAgent.get!/2,4)
  defp loop( stack, opts) do
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

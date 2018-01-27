xdefmodule MultiAgent.Worker do
  @moduledoc false

  alias MultiAgent.Callback

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

  defp execute({:update, from, {key, fun}}, opts) do
    change = execute({:cast, {key, fun}}, opts)
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


  defp call?(:infinity, _), do: true
  defp call?( until, call_expired_opt) do
    call_expired_opt || System.system_time < until
  end


  def loop( server, opts, threads_available \\ opts[:max_threads]) do
  end

  # process holds keys and states in process dictionary
  # so they are accessible at any time outside of process
  # (via MultiAgent specifically.get!/2,4)
  def loop( stack, opts) do
    receive do
      {action, until} ->

        if opts[:call_expired]
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

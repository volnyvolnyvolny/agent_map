defmodule AgentMap.Worker do
  @moduledoc false

  @compile {:inline, rand: 1, dec: 1, inc: 1, _dec: 1, _inc: 1}

  alias AgentMap.{Callback}

  @wait 10 #milliseconds

  @max_threads 5

  ##
  ## HELPERS
  ##

  def _dec(:infinity), do: :infinity
  def _dec(i), do: i-1

  def _inc(:infinity), do: :infinity
  def _inc(i), do: i+1

  def dec(key), do: Process.put key, _dec Process.get key
  def inc(key), do: Process.put key, _inc Process.get key


  # is OK for numbers < 1000
  defp rand(to), do: rem System.system_time, to


  ##
  ## PROCESS MSG
  ##

  defp process({:max_threads, value, from}) do
    GenServer.reply from, Process.get :'$max_threads'
    Process.put :'$max_threads', value
  end

  defp process({:get, fun, from}) do
    threads = Process.get :'$threads'

    if threads < Process.get :'$max_threads' do
      worker = self()
      state = Process.get :'$state'

      Task.start_link fn ->
        result = Callback.run fun, [state]
        GenServer.reply from, result
        send worker, :done
      end
      inc :'$threads'
    else
      state = Process.get :'$state'
      result = Callback.run fun, [state]
      GenServer.reply from, result
    end
  end

  defp process({:get_and_update, fun, from}) do
    state = Process.get :'$state'
    case Callback.run fun, [state] do
      {get} ->
        GenServer.reply from, get
      :id ->
        GenServer.reply from, state
      {get, state} ->
        process {:put, state}
        GenServer.reply from, get
      :pop ->
        process :drop
        GenServer.reply from, state
    end
  end

  defp process({:update, fun, from}) do
    process {:cast, fun}
    GenServer.reply from, :ok
  end

  defp process({:cast, fun}) do
    state = Process.get :'$state'
    Process.put :'$state', Callback.run(fun, [state])
  end

  defp process(:drop), do: Process.delete :'$state'
  defp process({:put, state}), do: Process.put :'$state', state
  defp process(:id), do: :ignore


  # transaction handler
  # only send current state
  defp process({:t_send, from}) do
    send from, {self(), Process.get :'$state'}
  end

  # receive the new state (maybe)
  defp process(:t_get) do
    receive do
      msg -> process msg
    end
  end

  # send and receive
  defp process({:t_send_and_get, from}) do
    process {:t_send, from}
    process :t_get
  end


  defp process(:done), do: dec :'$threads'
  defp process(:done_on_server), do: inc :'$max_threads'


  # main
  def loop(server, key, nil), do: loop server, key, {nil, @max_threads}
  def loop(server, key, {state, max_threads}) do
    if state do
      {:state, state} = state
      Process.put :'$state', state
    end

    Process.put :'$key', key
    Process.put :'$max_threads', max_threads
    Process.put :'$threads', 1 # the process that runs loop
    Process.put :'$gen_server', server
    Process.put :'$wait', @wait+rand(25)
    Process.put :'$selective_receive', true

    # :'$wait', :'$processes', :'max_processes', ':'$selective_receive' are
    # process keys, so they are easy to inspect from outside of the process
    loop() # →
  end


  defp _loop(selective \\ true) do
    wait = Process.get :'$wait'
    receive do
      {:!, msg} ->
        process msg
        loop selective
      msg ->
        process msg
        loop selective
    after wait ->
      send Process.get(:'$gen_server'), {self(), :mayidie?}
      receive do
        :continue ->
          # 1. next time wait a little bit longer (a few ms)
          Process.put :'$wait', wait+rand 5
          # 2. use selective receive (maybe, again)
          Process.put :'$selective_receive', true
          loop true

        :die! -> :bye
      end
    end
  end

  # →
  def loop(selective_receive \\ true)
  def loop(false), do: _loop(false)
  def loop(true) do
    {_, len} = Process.info self(), :message_queue_len
    if len > 100 do
      # turn off selective receive
      Process.put :'$selective_receive', false
      loop false
    end

    # selective receive
    receive do
      {:!, msg} ->
        process msg
        loop()
    after 0 ->
     _loop()
    end
  end

end

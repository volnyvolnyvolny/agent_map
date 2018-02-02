defmodule MultiAgent.Worker do
  @moduledoc false

  @compile {:inline, rand: 1, dec: 1, inc: 1}

  alias MultiAgent.Callback

  @wait 10 #milliseconds

  def dec(:infinity), do: :infinity
  def dec(x), do: x
  def inc(:infinity), do: :infinity
  def inc(x), do: x


  defp execute(:get, fun, from) do
    state = Process.get(:'$state')
    GenServer.reply( from, Callback.run( fun, [state]))
  end

  defp execute(:get_and_update, fun, from) do
    case Callback.run( fun, [Process.get(:'$state')]) do
      {result, state} ->
        Process.put(:'$state', state)
        GenServer.reply( from, result)
      :pop ->
        GenServer.reply( from, Process.delete(:'$state'))
    end
  end

  defp execute(:update, fun, from) do
    execute(:cast, fun)
    GenServer.reply( from, :ok)
  end

  defp execute(:cast, fun) do
    state = Process.get(:'$state')
    Process.put(:'$state', Callback.run( fun, [state]))
  end


  defp call?( expires) do
    late_call = Process.get(:'$late_call')
    Callback.call?( expires, late_call)
  end

  # get case if cannot create more threads
  defp process({:get, fun, from, expires}, threads_num) when threads_num > 1 do
    if call?( expires) do
      worker = self()
      Task.start_link( fn ->
        execute(:get, fun, from)
        unless threads_num == :infinity do
          send worker, :done
        end
      end)
      dec( threads_num)
    end
  end

  # get_and_update, update
  defp process({action, fun, from, expires}, threads_num) do
    if call?( expires),
      do: execute( action, fun, from)

    threads_num
  end

  defp process({:cast, fun}, threads_num) do
    execute(:cast, fun)
    threads_num
  end

  defp process(:die, threads_num) do
    Process.delete(:'$state')
    threads_num
  end

  defp process(:done, threads_num), do: inc(threads_num)

  defp process(:done_on_server, threads_num) do
    max_threads = Process.get(:'$max_threads')
    Process.put(:'$max_threads', max_threads+1)

    process(:done, threads_num)
  end


  # is OK for numbers < 1000
  defp rand( to), do: rem( System.system_time, to)

  # main
  def loop( server, key, {state, late_call, threads_num}) do
    if state = Callback.parse( state),
      do: Process.put(:'$state', state)
    if late_call,
      do: Process.put(:'$late_call', true)

    Process.put(:'$key', key)
    Process.put(:'$max_threads', threads_num)
    Process.put(:'$gen_server_pid', server)

    loop( true, @wait+rand(25), threads_num)
  end


  def loop( true, wait, threads_num) do
    if Process.info( self(), :message_queue_len) > 100 do
      # turn off selective receive
      loop( false, wait, threads_num)
    end

    # selective receive
    receive do
      {:!, msg} ->
        loop( true, wait, process( msg, threads_num))
    after 0 ->
      loop(:sub, wait, threads_num)
    end
  end

  def loop( s_receive, wait, threads_num) do
    s_receive = (s_receive == :sub)
    receive do
      {:!, msg} ->
        loop( s_receive, wait, process( msg, threads_num))
      msg ->
        loop( s_receive, wait, process( msg, threads_num))

      after wait ->
        send Process.get(:'$gen_server_pid'), {self(), :suicide?}
        receive do
          :continue ->
            # 1. next time wait a little bit longer (a few ms)
            # 2. use selective receive (maybe, again)
            loop( true, wait+rand(5), threads_num)
          :die! -> :bye
        end
    end
  end
end

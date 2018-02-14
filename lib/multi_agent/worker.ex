defmodule MultiAgent.Worker do
  @moduledoc false

  @compile {:inline, rand: 1, dec: 1, inc: 1, new_state: 1}

  alias MultiAgent.Callback

  @wait 10 #milliseconds

  #
  # HELPERS
  #

  def dec(:infinity), do: :infinity
  def dec(i) when is_integer(i), do: i-1
  def dec({state, late_call, t_num}), do: {state, late_call, dec(t_num)}
  def dec( key), do: Process.put key, dec( Process.get key)

  def inc(:infinity), do: :infinity
  def inc(i) when is_integer(i), do: i+1
  def inc({state, late_call, t_num}), do: {state, late_call, inc(t_num)}
  def inc( key), do: Process.put key, inc( Process.get key)


  def new_state( state \\ nil), do: {state, false, 4} # 5 processes per state by def


  defp call?(:infinity), do: true
  defp call?( exp), do: Process.get(:'$late_call') || (System.system_time < exp)

  # is OK for numbers < 1000
  defp rand( to), do: rem System.system_time, to


  #
  # PROCESS MSG
  #

  # get case if cannot create more threads
  defp process({:get, fun, from, expires}) do
    if call? expires do
      t_limit = Process.get :'$threads_limit'
      if t_limit > 1 do
        worker = self()
        state = Process.get :'$state'

        Task.start_link fn ->
          result = Callback.run fun, [state]
          GenServer.reply from, result
          unless t_limit == :infinity do
            send worker, :done
          end
        end
        dec :'$threads_limit'

      else
        state = Process.get :'$state'
        result = Callback.run fun, [state]
        GenServer.reply from, result
      end
    end
  end

  defp process({:get_and_update, fun, from, expires}) do
    if call? expires do
      state = Process.get :'$state'
      case Callback.run fun, [state] do
        {get, state} ->
          process {:new_state, state}
          GenServer.reply from, get
        :pop ->
          process :drop_state
          GenServer.reply from, state
      end
    end
  end

  defp process({:update, fun, from, expires}) do
    if call? expires do
      process {:cast, fun}
      GenServer.reply from, :ok
    end
  end

  defp process({:cast, fun}) do
    state = Process.get :'$state'
    Process.put :'$state', Callback.run( fun, [state])
  end

  defp process(:drop_state), do: Process.delete :'$state'
  defp process({:new_state, state}), do: Process.put :'$state', state
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


  defp process(:done), do: inc :'$threads_limit'
  defp process(:done_on_server) do
    inc :'$max_threads'
    process :done
  end


  # main
  def loop( server, key, nil), do: loop server, key, new_state()
  def loop( server, key, {state, late_call, threads_limit}) do
    if state = Callback.parse( state),
      do: Process.put(:'$state', state)
    if late_call,
      do: Process.put(:'$late_call', true)

    Process.put :'$key', key
    Process.put :'$max_threads', threads_limit
    Process.put :'$threads_limit', threads_limit # == max_threads
    Process.put :'$gen_server', server
    Process.put :'$wait', @wait+rand(25)
    Process.put :'$selective_receive', true

    # :'$wait', :'$threads_limit', :'$selective_receive' are process
    # keys, so they are easy to inspect from outside of the process
    loop() # →
  end


  defp common_rec( selective \\ true) do
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
  def loop( selective_receive \\ true)
  def loop( false), do: common_rec(false)
  def loop( true) do
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
      common_rec()
    end
  end

end

defmodule AgentMap.Worker do
  @moduledoc false

  @compile {:inline, rand: 1, dec: 1, inc: 1, _dec: 1, _inc: 1}

  alias AgentMap.Callback

  # milliseconds
  @wait 10

  @max_threads 5

  ##
  ## HELPERS
  ##

  def _dec(:infinity), do: :infinity
  def _dec(i), do: i - 1

  def _inc(:infinity), do: :infinity
  def _inc(i), do: i + 1

  def dec(key), do: Process.put(key, _dec(Process.get(key)))
  def inc(key), do: Process.put(key, _inc(Process.get(key)))

  defp unbox(:no), do: nil
  defp unbox({:value, value}), do: value

  def value(worker) do
    {_, dict} = Process.info(worker, :dictionary)
    value = dict[:"$value"]

    if value do
      unbox(value)
    else
      value(worker)
    end
  end

  # Is OK for numbers < 1000.
  defp rand(to), do: rem(System.system_time(), to)

  ##
  ## PROCESS MSG
  ##

  defp process({:max_threads, max_t, from}) do
    GenServer.reply(from, Process.get(:"$max_threads"))
    Process.put(:"$max_threads", max_t)
  end

  defp process({:get, fun, from}) do
    threads = Process.get(:"$threads")
    value = unbox(Process.get(:"$value"))

    if threads < Process.get(:"$max_threads") do
      worker = self()

      Task.start_link(fn ->
        result = Callback.run(fun, [value])
        GenServer.reply(from, result)
        send(worker, :done)
      end)

      inc(:"$threads")
    else
      result = Callback.run(fun, [value])
      GenServer.reply(from, result)
    end
  end

  defp process({:get_and_update, fun, from}) do
    value = unbox(Process.get(:"$value"))

    case Callback.run(fun, [value]) do
      {get} ->
        GenServer.reply(from, get)

      {get, value} ->
        process({:put, value})
        GenServer.reply(from, get)

      :id ->
        GenServer.reply(from, value)

      :pop ->
        process(:drop)
        GenServer.reply(from, value)
    end
  end

  defp process({:update, fun, from}) do
    process({:cast, fun})
    GenServer.reply(from, :ok)
  end

  defp process({:cast, fun}) do
    value = unbox(Process.get(:"$value"))
    process({:put, Callback.run(fun, [value])})
  end

  defp process(:drop), do: Process.put(:"$value", :no)
  defp process({:put, value}), do: Process.put(:"$value", {:value, value})
  defp process(:id), do: :ignore

  # Transaction handler.
  # Send current value.
  defp process({:t_send, from}) do
    send(from, {self(), unbox(Process.get(:"$value"))})
  end

  # Transaction handler.
  # Receive the new value (maybe).
  defp process(:t_get) do
    receive do
      msg -> process(msg)
    end
  end

  # Transaction handler.
  # Send and receive value.
  defp process({:t_send_and_get, from}) do
    process({:t_send, from})
    process(:t_get)
  end

  defp process(:done), do: dec(:"$threads")
  defp process(:done_on_server), do: inc(:"$max_threads")

  ##
  ## MAIN
  ##

  def loop(server, key, nil), do: loop(server, key, {nil, @max_threads})

  def loop(server, key, {value, max_threads}) do
    Process.put(:"$value", if(value, do: value, else: :no))
    Process.put(:"$key", key)
    Process.put(:"$max_threads", max_threads)
    # The process that runs loop.
    Process.put(:"$threads", 1)
    Process.put(:"$gen_server", server)
    Process.put(:"$wait", @wait + rand(25))
    Process.put(:"$selective_receive", true)

    # :'$wait', :'$processes', :'max_processes', ':'$selective_receive' are
    # process keys, so they are easy to inspect from outside of the process.
    # →
    loop()
  end

  defp _loop(selective \\ true) do
    wait = Process.get(:"$wait")

    receive do
      {:!, msg} ->
        process(msg)
        loop(selective)

      msg ->
        process(msg)
        loop(selective)
    after
      wait ->
        send(Process.get(:"$gen_server"), {self(), :mayidie?})

        receive do
          :continue ->
            # 1. next time wait a little bit longer (a few ms)
            Process.put(:"$wait", wait + rand(5))
            # 2. use selective receive (maybe, again)
            Process.put(:"$selective_receive", true)
            loop(true)

          :die! ->
            :bye
        end
    end
  end

  # →
  def loop(selective_receive \\ true)
  def loop(false), do: _loop(false)

  def loop(true) do
    {_, len} = Process.info(self(), :message_queue_len)

    if len > 100 do
      # Turn off selective receive.
      Process.put(:"$selective_receive", false)
      loop(false)
    end

    # Selective receive.
    receive do
      {:!, msg} ->
        process(msg)
        loop()
    after
      0 ->
        _loop()
    end
  end
end

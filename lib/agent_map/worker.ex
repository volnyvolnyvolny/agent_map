defmodule AgentMap.Worker do
  require Logger

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

  defp rand(to) when to < 1000 do
    rem(System.system_time(), to)
  end

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
      k = Process.get(:"$key")
      hv? = Process.get(:"$has_value?")

      Task.start_link(fn ->
        Process.put(:"$key", k)
        Process.put(:"$has_value?", hv?)

        result = Callback.run(fun, [value])
        GenServer.reply(from, result)
        send(worker, {:!, :done})
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

      {:chain, {key, fun}, value} ->
        process({:put, value})
        server = Process.get(:"$gen_server")
        send(server, {:chain, {key, fun}, from})

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

  defp process(:drop) do
    Process.put(:"$value", :no)
    Process.put(:"$has_value?", false)
  end

  defp process({:put, value}) do
    Process.put(:"$value", {:value, value})
    Process.put(:"$has_value?", true)
  end

  defp process(:id), do: :ignore

  # Transaction handler.
  # Sends current value.
  defp process({:t_send, from}) do
    send(from, {self(), unbox(Process.get(:"$value"))})
  end

  # Transaction handler.
  # Receives the new value (maybe).
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

  # Point of entry. Know nothing about value with given key.
  def loop(server, key, nil) do
    loop(server, key, {nil, @max_threads})
  end

  # → the value is known.
  def loop(server, key, {value, max_threads}) do
    if value do
      Process.put(:"$value", value)
      Process.put(:"$has_value?", true)
    else
      Process.put(:"$value", :no)
      Process.put(:"$has_value?", false)
    end

    Process.put(:"$key", key)
    Process.put(:"$max_threads", max_threads)

    # One (1) is for the process that runs loop.
    Process.put(:"$threads", 1)
    Process.put(:"$gen_server", server)
    Process.put(:"$wait", @wait + rand(25))
    Process.put(:"$selective_receive", true)

    # :'$wait', :'threads', :'max_threads', ':'$selective_receive' are
    # process keys, so they are easy to inspect from outside.
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

            # 2. use selective receive
            Process.put(:"$selective_receive", true)
            loop(true)

          :die! ->
            :bye
        end
    end
  end

  def loop(selective_receive \\ true)
  def loop(false), do: _loop(false)

  # →
  def loop(true) do
    {_, len} = Process.info(self(), :message_queue_len)

    if len > 100 do
      # Turn off selective receive.
      Process.put(:"$selective_receive", false)
      k = Process.get(:"$key")

      Logger.warn("""
        Selective receive is turned off for worker with key #{inspect(k)} as
        it's message queue became too long (#{len} messages). This prevents
        worker from executing the urgent calls out of turn. Selective receive
        will be turned on again as the queue became empty. This will not be
        logged.
      """)

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

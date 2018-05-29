defmodule AgentMap.Worker do
  require Logger

  alias AgentMap.{Callback, Req, MalformedCallback}

  import Process, only: [get: 1, put: 2, reply: 2]
  import System, only: [system_time: 0]
  import Req, only: [run: 2]

  @moduledoc false

  @compile {:inline, rand: 1, dec: 1, inc: 1}

  @wait 10 #ms

  ##
  ## HELPERS
  ##

  defp add(:infinity, _v), do: :infinity
  defp add(i, v), do: i + v

  def dec(key), do: put(key, add(get(key), -1))
  def inc(key), do: put(key, add(get(key), +1))

  def unbox(nil), do: nil
  def unbox({:value, value}), do: value

  def info(worker, key) do
    worker
    |> Process.info(key)
    |> elem(1)
  end

  def dict(worker), do: info(worker, :dictionary)

  def queue(worker), do: info(worker, :messages)

  def queue_len(worker \\ self()), do: info(worker, :message_queue_len)

  defp reply(to, what) do
    send(to, what)
  end

  defp set(value), do: put(:"$value", {:value, value})

  defp handle(%{action: :max_processes} = req) do
    reply(req.from, get(:"$max_processes"))
    put(:"$max_processes", req.value)
  end

  defp process(%{info: :done} = msg) do
    if msg[:on_server?] do
      inc(:"$max_processes")
    else
      dec(:"$processes")
    end
  end

  defp process(%{action: :get} = req) do
    value = unbox(get(:"$value"))

    if get(:"$processes") < get(:"$max_processes") do
      k = get(:"$key")
      v = get(:"$value")

      worker = self()

      Task.start_link(fn ->
        put(:"$key", k)
        put(:"$value", v)

        result = run(req, [value])
        reply(req.from, result)

        send(worker, %{info: :done, !: true})
      end)

      inc(:"$processes")
    else
      result = run(req, [value])
      reply(req.from, result)
    end
  end

  defp process(%{action: :get_and_update} = req) do
    value = unbox(get(:"$value"))

    with {:ok, reply} <- run(req, [value]) do
      case reply do
        {get} ->
          reply(req.from, get)

        {get, value} ->
          set(value)
          reply(req.from, get)

        {:chain, {_kf, _fks} = d, value} ->
          set(value)

          req =
            req
            |> Map.delete(:fun)
            |> Map.put(action: :get_and_update)
            |> Map.put(data: d)

          send(get(:"$gen_server"), req)

        :id ->
          reply(req.from, value)

        :pop ->
          delete(:"$value")
          reply(req.from, value)

        reply ->
          e = %MalformedCallback{for: :get_and_update, got: r}

          if req.safe? do
            Logger.error(Exception.message(e))
          else
            raise e
          end
      end
    else
      {:error, r} ->
        Logger.error(r)
    end
  end

  defp process(%{action: :drop}), do: delete(:"$value")

  defp process(%{action: :put} = req), do: set(req.value)

  defp process(%{action: :send} = req) do
    reply(req.to, {self(), get(:"$value")})
  end

  defp process(%{action: :receive} = req) do
    receive do
      :id ->
        :ignore

      :drop ->
        delete(:"$value")

      {:value, v} ->
        set(v)

    after 0 ->
      process(req)
    end
  end

  defp process(%{action: :send_and_receive} = req) do
    process(%{req | action: :send})
    process(%{req | action: :receive})
  end

  ##
  ## MAIN
  ##

  # →
  def loop({ref, server}, key, {value, max_processes}) do
    put(:"$value", value)
    send(server, {ref, :ok})

    put(:"$key", key)
    put(:"$gen_server", server)

    # One (1) process is for loop.
    put(:"$processes", 1)
    put(:"$max_processes", max_processes)

    put(:"$wait", @wait + rand(25))
    put(:"$selective_receive", true)

    # →
    loop()
  end

  # →→→
  defp _loop(selective \\ true) do
    wait = get(:"$wait")

    receive do
      req ->
        process(req)
        loop(selective)

    after
      wait ->
        send(get(:"$gen_server"), {self(), :mayidie?})

        receive do
          :continue ->
            # 1. Next time wait a few ms longer;
            put(:"$wait", wait + rand(5))

            # 2. use selective receive.
            put(:"$selective_receive", true)
            loop(true)

          :die! ->
            :bye
        end
    end
  end

  def loop(selective_receive \\ true)
  def loop(false), do: _loop(false)

  # →→
  def loop(_) do
    if queue_len() > 100 do
      # Turn off selective receive.
      put(:"$selective_receive", false)

      Logger.warn("""
        Selective receive is turned off for worker with
        key #{inspect(get(:"$key"))} as it's message queue became too long
        (#{queue_len()} messages). This prevents worker from executing the
        urgent calls out of turn. Selective receive will be turned on again as
        the queue became empty (which will not be shown in logs).
      """
      |> String.replace("\n", " "))

      loop(false)
    end

    # Selective receive.
    receive do
      %{!: true} = req ->
        process(req)
        loop()
    after
      0 ->
        _loop()
    end
  end
end

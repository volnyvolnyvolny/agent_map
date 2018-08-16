defmodule AgentMap.Worker do
  require Logger

  alias AgentMap.{Common, CallbackError}

  import Process, only: [get: 1, put: 2, delete: 1, info: 1]
  import System, only: [system_time: 0]
  import Common, only: [run: 2, reply: 2, handle_timeout_error: 1]

  @moduledoc false

  @compile {:inline,
            rand: 1, dec: 1, inc: 1, add: 2, unbox: 1, set: 1, dict: 1, queue: 1, queue_len: 1}

  # ms
  @wait 10

  ##
  ## HELPERS
  ##

  # Greate for generating numbers < 1000.
  defp rand(to) when to < 1000, do: rem(system_time(), to)

  defp set(value), do: put(:"$value", {:value, value})

  ##
  ## DICTIONARY
  ##

  defp add(:infinity, _v), do: :infinity
  defp add(i, v), do: i + v

  defp dec(key), do: put(key, add(get(key), -1))
  defp inc(key), do: put(key, add(get(key), +1))

  def dict(worker \\ self()), do: info(worker)[:dictionary]
  def queue(worker), do: info(worker)[:messages]
  def queue_len(worker \\ self()), do: info(worker)[:message_queue_len]

  ##
  ## HANDLE
  ##

  defp reply(nil, msg), do: :ignore
  defp reply(from, msg), do: GenServer.reply(from, msg)

  defp handle(%{action: :max_processes} = req) do
    GenServer.reply(req.from, get(:"$max_processes"))
    put(:"$max_processes", req.data)
  end

  defp handle(%{action: :get} = req) do
    run_and_reply = fn req, value ->
      case run(req, unbox(value)) do
        {:ok, result} ->
          GenServer.reply(req.from, result)

        {:error, :expired} ->
          handle_timeout_error(req)
      end
    end

    k = get(:"$key")
    v = get(:"$value")

    if get(:"$processes") < get(:"$max_processes") do
      worker = self()

      Task.start_link(fn ->
        for {prop, value} <- dict(worker) do
          put(prop, value)
        end

        run_and_reply.(req, v)

        send(worker, %{info: :done, !: true})
      end)

      inc(:"$processes")
    else
      run_and_reply.(req, v)
    end
  end

  defp handle(%{action: :get_and_update} = req) do
    value = unbox(get(:"$value"))

    case run(req, [value]) do
      {:ok, {get}} ->
        reply(req.from, get)

      {:ok, {get, v}} ->
        put(:"$value", {:value, v})
        reply(req.from, get)

      {:ok, {:chain, {_kf, _fks} = d, v}} ->
        put(:"$value", {:value, v})

        req = %{req | data: d, action: :chain}
        send(get(:"$gen_server"), req)

      {:ok, :id} ->
        reply(req.from, value)

      {:ok, :pop} ->
        delete(:"$value")
        reply(req.from, value)

      {:ok, reply} ->
        raise CallbackError, got: reply

      {:error, :expired} ->
        handle_timeout_error(req)
    end
  end

  defp handle(%{action: :drop}) do
    delete(:"$value")
  end

  defp handle(%{action: :send} = req) do
    send(req.to, {self(), get(:"$value")})
  end

  defp handle(%{action: :receive} = req) do
    receive do
      :id ->
        :ignore

      :drop ->
        delete(:"$value")

      {:value, v} = box ->
        put(:"$value", box)
    after
      0 ->
        handle(req)
    end
  end

  defp handle(%{action: :send_and_receive} = req) do
    handle(%{req | action: :send})
    handle(%{req | action: :receive})
  end

  ##
  ## MAIN
  ##

  # →
  # value = {:value, any} | nil
  def loop({ref, server}, key, {value, {p, max_p}}) do
    put(:"$value", value)
    send(server, {ref, :ok})

    put(:"$key", key)
    put(:"$gen_server", server)

    # One (1) process is for loop.
    put(:"$processes", p + 1)
    put(:"$max_processes", max_p)

    put(:"$wait", @wait + rand(25))
    put(:"$selective_receive", true)

    # →
    loop()
  end

  # →→
  def loop() do
    if get(:"$selective_receive") do
      if queue_len() > 100 do
        # Turn off selective receive.
        put(:"$selective_receive", false)

        Logger.warn(
          """
          Selective receive is turned off for worker with
          key #{inspect(get(:"$key"))} as it's message queue became too long
          (#{queue_len()} messages). This prevents worker from executing the
          out of turn calls. Selective receive will be turned on again as
          the queue became empty (this will not be shown in logs).
          """
          |> String.replace("\n", " ")
        )

        loop()
      else
        # Selective receive.
        receive do
          %{info: :done} ->
            dec(:"$processes")
            loop()

          %{!: true} = req ->
            handle(req)
            loop()
        after
          0 ->
            # Process other msgs.
            _loop()
        end
      end
    else
      _loop()
    end
  end

  # →→→
  defp _loop() do
    wait = get(:"$wait")

    receive do
      req ->
        handle(req)
        loop()
    after
      wait ->
        send(get(:"$gen_server"), {self(), :mayidie?})

        receive do
          :continue ->
            # 1. Next time wait a few ms longer:
            put(:"$wait", wait + rand(5))

            # 2. use selective receive again:
            put(:"$selective_receive", true)
            loop()

          :die! ->
            :bye
        end
    end
  end
end

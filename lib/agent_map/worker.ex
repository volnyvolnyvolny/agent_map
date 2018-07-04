defmodule AgentMap.Worker do
  require Logger

  alias AgentMap.{Common, MalformedCallback}

  import Process, only: [get: 1, put: 2, delete: 1, exit: 2]
  import System, only: [system_time: 0]
  import Common, only: [run: 2, reply: 2, run_and_reply: 2]

  @moduledoc false

  @compile {:inline,
            rand: 1,
            dec: 1,
            inc: 1,
            add: 2,
            unbox: 1,
            set: 1,
            info: 2,
            dict: 1,
            queue: 1,
            queue_len: 1}

  # ms
  @wait 10

  ##
  ## HELPERS
  ##

  # Greate for generating numbers < 1000.
  defp rand(to) when to < 1000, do: rem(system_time(), to)

  defp add(:infinity, _v), do: :infinity
  defp add(i, v), do: i + v

  def dec(key), do: put(key, add(get(key), -1))
  def inc(key), do: put(key, add(get(key), +1))

  def unbox(nil), do: nil
  def unbox({:value, value}), do: value

  defp set(value), do: put(:"$value", {:value, value})

  def info(worker, key) do
    worker
    |> Process.info(key)
    |> elem(1)
  end

  def dict(worker), do: info(worker, :dictionary)

  def queue(worker), do: info(worker, :messages)

  def queue_len(worker \\ self()) do
    info(worker, :message_queue_len)
  end

  ##
  ## HANDLE
  ##

  defp handle(%{action: :max_processes} = req) do
    reply(req.from, get(:"$max_processes"))
    put(:"$max_processes", req.data)
  end

  defp handle(%{action: :get} = req) do
    value = unbox(get(:"$value"))

    if get(:"$processes") < get(:"$max_processes") do
      k = get(:"$key")
      v = get(:"$value")

      worker = self()

      Task.start_link(fn ->
        put(:"$key", k)
        put(:"$value", v)

        run_and_reply(req, value)
        reply(worker, %{info: :done, !: true})
      end)

      inc(:"$processes")
    else
      run_and_reply(req, value)
    end
  end

  defp handle(%{action: :get_and_update} = req) do
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

          req = %{req | data: d, action: :chain}
          send(get(:"$gen_server"), req)

        :id ->
          reply(req.from, value)

        :pop ->
          delete(:"$value")
          reply(req.from, value)

        reply ->
          raise %MalformedCallback{for: :get_and_update, got: reply}
      end
    else
      {:error, reason} ->
        k = get(:"$key")
        Logger.error("Key #{k} error while processing #{inspect(req)}. Reason: #{reason}.")
    end
  end

  defp handle(%{action: :drop}) do
    delete(:"$value")
  end

  defp handle(%{action: :put} = req) do
    set(req.value)
  end

  defp handle(%{action: :send} = req) do
    reply(req.to, {self(), get(:"$value")})
  end

  defp handle(%{action: :receive} = req) do
    receive do
      :id ->
        :ignore

      :drop ->
        delete(:"$value")

      {:value, v} ->
        set(v)
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

  def loop(back_link, key, {value, max_p}) do
    loop(back_link, key, {value, {0, max_p}})
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
            urgent calls out of turn. Selective receive will be turned on again as
            the queue became empty (which will not be shown in logs).
          """
          |> String.replace("\n", " ")
        )

        loop()
      else
        # Selective receive.
        receive do
          %{info: :get!} ->
            inc(:"$processes")
            loop()

          %{info: :done} ->
            dec(:"$processes")
            loop()

          %{action: :get, !: true} = req ->
            handle(req)
            loop()
        after
          0 ->
            receive do
              %{!: true} = req ->
                handle(req)
                loop()
            after
              0 ->
                # Process other msgs.
                _loop()
            end
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
            # 1. Next time wait a few ms longer;
            put(:"$wait", wait + rand(5))

            # 2. use selective receive as queue is empty.
            put(:"$selective_receive", true)
            loop()

          :die! ->
            :bye
        end
    end
  end
end

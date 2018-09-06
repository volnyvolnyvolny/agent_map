defmodule AgentMap.Worker do
  require Logger

  alias AgentMap.{Common, CallbackError, Server.State}

  import Process, only: [get: 1, put: 2, delete: 1, info: 1]
  import Common, only: [run: 3, reply: 2, now: 0]
  import State, only: [un: 1, box: 1]

  @moduledoc false

  @compile {:inline, rand: 1, dict: 1, queue: 1, queue_len: 1}

  # ms
  @wait 10

  ##
  ## CALLBACKS
  ##

  def share_value(to: t) do
    key = Process.get(:"$key")
    box = Process.get(:"$value")
    send(t, {key, box})
  end

  def accept_value(ref) do
    receive do
      {^ref, :drop} ->
        :pop

      {^ref, :id} ->
        :id

      {^ref, box} ->
        {:_get, un(box)}
    end
  end

  ##
  ## HELPERS
  ##

  # Great for generating numbers < 100.
  defp rand(to) when to < 100, do: rem(now(), to)

  ##
  ## DICTIONARY
  ##

  def dict(worker \\ self()), do: info(worker)[:dictionary]
  def queue(worker), do: info(worker)[:messages]
  def queue_len(worker \\ self()), do: info(worker)[:message_queue_len]

  ##
  ## MESSAGE
  ##

  def spawn_get_task(msg, {key, box}, opts \\ [server: self()]) do
    Task.start_link(fn ->
      Process.put(:"$key", key)
      Process.put(:"$value", box)

      case run(msg.fun, [un(box)], opts(msg)) do
        {:ok, get} ->
          reply(msg[:from], get)

        e ->
          Worker.handle_error(e, msg)
      end

      send(opts[:server], %{info: :done, key: key})
    end)
  end

  def opts(%{timeout: {a, t}, inserted_at: i} = _msg) do
    %{timeout: t, inserted_at: i, break: a == :break}
  end

  def opts(_), do: %{}

  ##
  ## HANDLERS
  ##

  defp handle(%{action: :get} = msg) do
    p = get(:"$processes")
    box = get(:"$value")
    max_p = get(:"$max_processes")

    if p < max_p do
      k = get(:"$key")
      s = get(:"$server")

      spawn_get_task(msg, {k, box}, server: s)

      put(:"$processes", p + 1)
    else
      case run(msg.fun, [un(box)], opts(msg)) do
        {:ok, get} ->
          reply(msg[:from], get)

        e ->
          handle_error(e, msg)
      end
    end
  end

  defp handle(%{action: :get_and_update} = msg) do
    box = get(:"$value")
    arg = un(box)

    case run(msg.fun, [arg], opts(msg)) do
      {:ok, {get}} ->
        reply(msg[:from], get)

      {:ok, {get, v}} ->
        put(:"$value", box(v))
        reply(msg[:from], get)

      {:ok, :id} ->
        reply(msg[:from], arg)

      {:ok, :pop} ->
        delete(:"$value")
        reply(msg[:from], arg)

      {:ok, reply} ->
        raise CallbackError, got: reply

      e ->
        handle_error(e, msg)
    end
  end

  defp handle(%{action: :max_processes} = msg) do
    reply(msg.from, get(:"$max_processes"))
    put(:"$max_processes", msg.data)
  end

  defp handle_error({:error, :expired}, msg) do
    k = inspect(get(:"$key"))
    Logger.error("Key #{k} call is expired and will not be executed. Details: #{inspect(msg)}.")
  end

  defp handle_error({:error, :toolong}, msg) do
    k = inspect(get(:"$key"))
    Logger.error("Key #{k} call takes too long and will be terminated. Details: #{inspect(msg)}.")
  end

  ##
  ## MAIN
  ##

  # →
  # value = {:value, any} | nil
  def loop({ref, server}, key, {box, {p, max_p}}) do
    put(:"$value", box)
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
            p = get(:"$processes")
            put(:"$processes", p - 1)
            loop()

          %{info: :get!} ->
            p = get(:"$processes")
            put(:"$processes", p + 1)
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
      %{} = req ->
        handle(req)
        loop()

      _ ->
        :drop
    after
      wait ->
        send(get(:"$gen_server"), {self(), :mayidie?})

        receive do
          :continue ->
            # 1. Next time wait a few ms longer:
            put(:"$wait", wait + rand(5))

            # 2. Use selective receive again:
            put(:"$selective_receive", true)
            loop()

          :die! ->
            :bye
        end
    end
  end
end

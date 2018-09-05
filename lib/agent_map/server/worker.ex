defmodule AgentMap.Worker do
  require Logger

  alias AgentMap.{Common, CallbackError, Server.State}

  import Process, only: [get: 1, put: 2, delete: 1, info: 1]
  import System, only: [system_time: 0]
  import Common, only: [run: 3, reply: 2]
  import State

  @moduledoc false

  @compile {:inline, rand: 1, dict: 1, queue: 1, queue_len: 1}

  # ms
  @wait 10

  ##
  ## HELPERS
  ##

  # Great for generating numbers < 100.
  defp rand(to) when to < 100, do: rem(system_time(), to)

  ##
  ## DICTIONARY
  ##

  def dict(worker \\ self()), do: info(worker)[:dictionary]
  def queue(worker), do: info(worker)[:messages]
  def queue_len(worker \\ self()), do: info(worker)[:message_queue_len]

  ##
  ## HANDLERS
  ##

  def run_and_reply(fun, arg, opts) do
    from = opts[:from]

    case run(fun, arg, opts) do
      {:ok, result} ->
        if opts.action == :get_and_update do
          case result do
            {get} ->
              reply(from, get)

            {get, v} ->
              put(:"$value", box(v))
              reply(from, get)

            :id ->
              reply(from, arg)

            :pop ->
              delete(:"$value")
              reply(from, arg)

            reply ->
              raise CallbackError, got: reply
          end
        end || reply(opts[:from], result)

      e ->
        handle_error(e, opts)
    end
  end

  defp handle(%{action: :get} = msg) do
    b = get(:"$value")
    p = get(:"$processes")
    max_p = get(:"$max_processes")

    if p < max_p do
      k = get(:"$key")
      s = get(:"$server")

      Task.start_link(fn ->
        put(:"$key", k)
        put(:"$value", b)

        run_and_reply(msg.fun, unbox(b), msg)

        send(s, %{info: :done, key: k})
      end)

      put(:"$processes", p + 1)
    else
      run_and_reply(msg.fun, unbox(b), msg)
    end
  end

  defp handle(%{action: :get_and_update} = msg) do
    b = get(:"$value")
    run_and_reply(msg.fun, unbox(b), msg)
  end

  defp handle(%{action: :max_processes} = msg) do
    reply(msg.from, get(:"$max_processes"))
    put(:"$max_processes", msg.data)
  end

  defp err_msg({:error, :expired}, k, r) do
    "Key #{k} call is expired and will not be executed. Req: #{r}."
  end

  defp err_msg({:error, :toolong}, k, r) do
    "Key #{k} call takes too long and will be terminated. Req: #{r}."
  end

  def handle_error(e, details) do
    k = inspect(Process.get(:"$key"))
    r = inspect(details)
    Logger.error(err_msg(e, k, r))
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
        :ignore
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

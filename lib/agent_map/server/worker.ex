defmodule AgentMap.Worker do
  require Logger

  alias AgentMap.{Common, CallbackError, Server.State, Req}

  import Process, only: [get: 1, put: 2, delete: 1, info: 1]
  import Common, only: [run: 4, reply: 2, now: 0, left: 2]
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

  def accept_value() do
    receive do
      :drop ->
        :pop

      :id ->
        :id

      box ->
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
  ## REQUEST
  ##

  defp timeout(%{timeout: {_, t}, inserted_at: i}), do: left(t, since: i)
  defp timeout(%{}), do: :infinity

  def spawn_get_task(req, {key, box}, opts \\ [server: self()]) do
    Task.start_link(fn ->
      Process.put(:"$key", key)
      Process.put(:"$value", box)

      break? = match?({:break, _}, req[:timeout])
      t_left = timeout(req)

      case run(req.fun, [un(box)], t_left, break?) do
        {:ok, get} ->
          reply(req[:from], get)

        e ->
          handle_error(e, req)
      end

      done = %{info: :done, key: key}
      w = opts[:worker]
      s = opts[:server]

      if w && Process.alive?(w) do
        send(w, done)
      else
        send(s, done)
      end
    end)
  end

  ##
  ## HANDLERS
  ##

  defp handle(%{action: :get} = req) do
    p = get(:"$processes")
    box = get(:"$value")
    max_p = get(:"$max_processes")

    if p < max_p do
      k = get(:"$key")
      s = get(:"$server")

      spawn_get_task(req, {k, box}, server: s, worker: self())

      put(:"$processes", p + 1)
    else
      break? = match?({:break, _}, req[:timeout])
      t_left = timeout(req)

      case run(req.fun, [un(box)], t_left, break?) do
        {:ok, get} ->
          reply(req[:from], get)

        e ->
          handle_error(e, req)
      end
    end
  end

  defp handle(%{action: :get_and_update} = req) do
    box = get(:"$value")
    arg = un(box)

    break? = match?({:break, _}, req[:timeout])
    t_left = timeout(req)

    case run(req.fun, [arg], t_left, break?) do
      {:ok, {get}} ->
        reply(req[:from], get)

      {:ok, {get, v}} ->
        put(:"$value", box(v))
        reply(req[:from], get)

      {:ok, :id} ->
        reply(req[:from], arg)

      {:ok, :pop} ->
        delete(:"$value")
        reply(req[:from], arg)

      {:ok, reply} ->
        raise CallbackError, got: reply

      e ->
        handle_error(e, req)
    end
  end

  defp handle(%{action: :max_processes} = req) do
    reply(req.from, get(:"$max_processes"))
    put(:"$max_processes", req.data)
  end

  defp handle(%{info: :done}) do
    p = get(:"$processes")
    put(:"$processes", p - 1)
  end

  defp handle(%{info: :get!}) do
    p = get(:"$processes")
    put(:"$processes", p + 1)
  end

  defp handle(msg) do
    k = inspect(get(:"$key"))

    Logger.warn("""
    Worker (key: #{k}) got unexpected message #{inspect(msg)}
    """)
  end

  defp handle_error({:error, :expired}, req) do
    Logger.error("""
    Key #{inspect(get(:"$key"))} call is expired and will not be executed.
    Details: #{inspect(req)}.
    """)
  end

  defp handle_error({:error, :toolong}, req) do
    Logger.error("""
    Key #{inspect(get(:"$key"))} call takes too long and will be terminated.
    Details: #{inspect(req)}.
    """)
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
          (#{queue_len()} messages). This prevents worker from executing the out
          of turn calls. Selective receive will be turned on again as the queue
          became empty (this will not be shown in logs).
          """
          |> String.replace("\n", " ")
        )

        loop()
      else
        # Selective receive.
        receive do
          %{info: _} = msg ->
            handle(msg)
            loop()

          %{!: true} = req ->
            handle(req)
            loop()
        after
          0 ->
            # Process other reqs.
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
        send(get(:"$gen_server"), {self(), :die?})

        receive do
          :die! ->
            :bye

          req ->
            handle(req)

            # 1. Next time wait a few ms longer:
            put(:"$wait", wait + rand(5))

            # 2. Use selective receive again:
            put(:"$selective_receive", true)
            loop()
        end
    end
  end
end

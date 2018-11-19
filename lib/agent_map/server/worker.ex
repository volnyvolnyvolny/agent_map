defmodule AgentMap.Worker do
  require Logger

  alias AgentMap.{Time, CallbackError}

  import Process, only: [get: 1, put: 2, delete: 1]
  import Time, only: [now: 0]

  @moduledoc false

  @compile {:inline, rand: 1, dict: 1, inc: 1, dec: 1}

  # ms
  @wait 10

  #

  def reply(nil, _msg), do: :nothing
  def reply({_p, _ref} = from, msg), do: GenServer.reply(from, msg)
  def reply(from, msg), do: send(from, msg)

  #

  defp rand(n) when n < 100, do: rem(now(), n)

  def info(worker, key) do
    Process.info(worker, key) |> elem(1)
  end

  defp max_processes() do
    max_p = get(:max_processes)

    unless max_p do
      pid = get(:gen_server)
      dict(pid)[:max_processes]
    else
      max_p
    end
  end

  def dict(worker \\ self()) do
    info(worker, :dictionary)
  end

  def processes(worker) do
    ps =
      Enum.count(
        info(worker, :messages),
        &match?(%{info: :get!}, &1)
      )

    dict(worker)[:processes] + ps
  end

  def dec(key), do: put(key, get(key) - 1)

  def inc(key), do: put(key, get(key) + 1)

  ##
  ## CALLBACKS
  ##

  def share_value(to: me) do
    key = Process.get(:key)
    box = Process.get(:value)
    reply(me, {key, box})
  end

  def accept_value() do
    receive do
      :drop ->
        :pop

      :id ->
        :id

      {:value, v} ->
        {:_get, v}
    end
  end

  ##
  ## REQUEST
  ##

  defp run(req, value) do
    arg =
      case value do
        {:value, v} ->
          v

        nil ->
          Map.get(req, :data)
      end

    interpret(req, arg, apply(req.fun, [arg]))
  end

  #

  defp interpret(%{act: :get} = req, _arg, get) do
    from = Map.get(req, :from)

    reply(from, get)
  end

  # act: :get_and_update
  defp interpret(req, arg, ret) do
    from = Map.get(req, :from)

    case ret do
      {get} ->
        reply(from, get)

      {get, v} ->
        put(:value, {:value, v})
        reply(from, get)

      :id ->
        reply(from, arg)

      :pop ->
        delete(:value)
        reply(from, arg)

      reply ->
        raise CallbackError, got: reply
    end
  end

  #

  def spawn_get_task(req, {key, box}, opts \\ [server: self()]) do
    Task.start_link(fn ->
      put(:key, key)
      put(:value, box)

      run(req, box)

      done = %{info: :done, key: key}
      worker = opts[:worker]

      if worker && Process.alive?(worker) do
        send(worker, done)
      else
        send(opts[:server], done)
      end
    end)
  end

  ##
  ## HANDLERS
  ##

  defp handle(%{act: :get} = req) do
    box = get(:value)

    if get(:processes) < max_processes() do
      spawn_get_task(
        req,
        {get(:key), box},
        server: get(:gen_server),
        worker: self()
      )

      inc(:processes)
    else
      run(req, box)
    end
  end

  defp handle(%{act: :get_and_update} = req) do
    run(req, get(:value))
  end

  defp handle(%{act: :max_processes} = req) do
    put(:max_processes, req.data)
  end

  defp handle(%{info: :done}), do: dec(:processes)
  defp handle(%{info: :get!}), do: inc(:processes)

  defp handle(msg) do
    Logger.warn("""
    Worker got unexpected message.
    Key: #{inspect(get(:key))}.
    Message: #{inspect(msg)}.
    """)
  end

  ##
  ## MAIN
  ##

  # box = {:value, any} | nil
  def loop({ref, server}, key, {box, {p, max_p}}) do
    put(:value, box)

    # One (1) process is for loop.
    put(:processes, p + 1)
    put(:max_processes, max_p)

    send(server, {ref, :ok})

    put(:key, key)
    put(:gen_server, server)

    put(:wait, @wait + rand(25))

    loop(Heap.max())
    # →
  end

  # →
  defp loop(%_{size: 0} = heap) do
    wait = get(:wait)

    receive do
      req ->
        place(heap, req) |> loop()
    after
      wait ->
        send(get(:gen_server), {self(), :die?})

        receive do
          :die! ->
            :bye

          :continue ->
            # Next time wait a few ms more.
            wait = get(:wait)
            put(:wait, wait + rand(5))
            loop(heap)
        end
    end
  end

  defp loop(heap) do
    {{_, _, req}, rest} =
      heap
      |> flush()
      |> Heap.split()

    handle(req)
    loop(rest)
  end

  # Flush mailbox.
  defp flush(heap) do
    receive do
      req ->
        place(heap, req) |> flush()
    after
      0 ->
        heap
    end
  end

  #
  defp place(heap, req) do
    case req do
      %{info: _} = msg ->
        handle(msg)
        heap

      req ->
        Heap.push(heap, {req[:!], -now(), req})
    end
  end
end

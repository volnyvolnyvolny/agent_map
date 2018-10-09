defmodule AgentMap.Worker do
  require Logger

  alias AgentMap.{Common, CallbackError, Server.State}

  import Process, only: [get: 1, put: 2, delete: 1]
  import Common, only: [run: 4, reply: 2, now: 0, left: 2]
  import State, only: [un: 1, box: 1]

  @moduledoc false

  @compile {:inline, rand: 1, dict: 1, busy?: 1}
  @avg 256

  # ms
  @wait 10

  defp rand(n) when n < 100, do: rem(now(), n)

  defp info(worker, key) do
    Process.info(worker, key) |> elem(1)
  end

  defp max_processes() do
    unless max_p = get(:max_processes) do
      dict(get(:gen_server))[:max_processes]
    else
      max_p
    end
  end

  def dict(worker \\ self()), do: info(worker, :dictionary)

  def busy?(worker) do
    info(worker, :message_queue_len) > 0
  end

  def processes(worker) do
    ps =
      Enum.count(
        info(worker, :messages),
        &match?(%{info: :get!}, &1)
      )

    IO.inspect(get(:processes)) + ps
  end

  ##
  ## CALLBACKS
  ##

  def share_value(to: me) do
    key = Process.get(:key)
    box = Process.get(:value)
    delete(:dontdie?)
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

  defp timeout(%{timeout: {_, t}, inserted_at: i}), do: left(t, since: i)
  defp timeout(%{}), do: :infinity

  defp run(req, box) do
    break? = match?(%{timeout: {:break, _}}, req)
    t_left = timeout(req)

    arg =
      if box do
        un(box)
      else
        Map.get(req, :data)
      end

    res = run(req.fun, [arg], t_left, break?)
    interpret(req, arg, res)
  end

  defp interpret(%{action: :get} = req, _arg, {:ok, get}) do
    Map.get(req, :from) |> reply(get)
  end

  # action: :get_and_update
  defp interpret(req, arg, {:ok, ret}) do
    from = Map.get(req, :from)

    case ret do
      {get} ->
        reply(from, get)

      {get, v} ->
        put(:value, box(v))
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

  defp interpret(req, arg, {:error, :expired}) do
    key = get(:key)

    Logger.error("""
    Key #{inspect(key)} call is expired and will not be executed.
    Request: #{inspect(req)}.
    Value: #{inspect(arg)}.
    """)
  end

  defp interpret(req, arg, {:error, :toolong}) do
    key = get(:key)

    Logger.error("""
    Key #{inspect(key)} call takes too long and will be terminated.
    Request: #{inspect(req)}.
    Value: #{inspect(arg)}.
    """)
  end

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

  defp handle(%{action: :get} = req) do
    box = get(:value)

    p = get(:processes)

    if p < max_processes() do
      key = get(:key)
      s = get(:gen_server)

      spawn_get_task(req, {key, box}, server: s, worker: self())

      put(:processes, p + 1)
    else
      run(req, box)
    end
  end

  defp handle(%{action: :get_and_update} = req) do
    run(req, get(:value))
  end

  defp handle(%{action: :max_processes} = req) do
    put(:max_processes, req.data)
  end

  defp handle(%{info: :done}) do
    p = get(:processes)
    put(:processes, p - 1)
  end

  defp handle(%{info: :get!}) do
    p = get(:processes)
    put(:processes, p + 1)
  end

  defp handle(:dontdie!) do
    put(:dontdie?, true)
  end

  defp handle(msg) do
    k = inspect(get(:key))

    Logger.warn("""
    Worker (key: #{k}) got unexpected message #{inspect(msg)}
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

    # →
    loop({Heap.new, []})
  end

  # →
  defp loop({%_{size: 0}, []} = state) do
    wait = get(:wait)

    receive do
      req ->
        place(state, req) |> loop()
    after
      wait ->
        if get(:dontdie?) do
          loop(state)
        else
          send(get(:gen_server), {self(), :die?})

          receive do
            :die! ->
              :bye

            :continue ->
              # Next time wait a few ms more.
              wait = get(:wait)
              put(:wait, wait + rand(5))
              loop(state)
          end
        end
    end
  end

  defp loop({_heap, [%{action: :get} = req | _]} = state) do
    state = {heap, queue} = flush(state)

    if get(:processes) < get(:max_processes) do
      [_req | tail] = queue
      handle(req)
      loop({heap, tail})
    else
      run(state) |> loop()
    end
  end

  defp loop({heap, queue}) do
    unless Heap.empty?(heap) || [] == queue do
      run(state) |> loop()
    else
      receive do
        req ->
          place(state, req) |> loop()
      after
        0 ->
          # Mailbox is empty. Run:
          run(state) |> loop()
      end
    end
  end

  #

  defp run({%_{size: 0}, [req | tail]}) do
    handle(req)
    {Heap.new(), tail}
  end

  defp run({heap, [%{action: :get_and_update} | _] = queue}) do
    for req <- heap do
      handle(req)
    end

    {Heap.new(), queue}
  end

  defp run({heap, queue}) do
    {req, rest} = Heap.split(heap)

    handle(req)
    {rest, queue}
  end

  #

  # Mailbox → queues.
  defp flush(state) do
    receive do
      req ->
        place(state, req) |> flush()
    after
      0 ->
        state
    end
  end

  #

  # Req → queues.
  defp place({p_queue, queue} = state, req) do
    case req do
      %{info: _} = msg ->
        handle(msg)
        state

      %{!: @avg} = req ->
        {[req | p_queue], queue}

      _ ->
        {p_queue, queue ++ [req]}
    end
  end
end

defmodule AgentMap.Worker do
  @moduledoc false

  require Logger

  alias AgentMap.Req

  import Process, only: [get: 1, put: 2, info: 2, delete: 1, alive?: 1]

  @compile {:inline, rand: 1, dict: 1, inc: 1, dec: 1}

  # ms
  @wait 10

  #

  defp now(), do: System.monotonic_time()

  defp rand(n) when n < 100, do: rem(abs(now()), n)

  #

  defp to_num(:now), do: :now

  defp to_num(p) when p in [:min, :low], do: 0
  defp to_num(p) when p in [:avg, :mid], do: 255
  defp to_num(p) when p in [:max, :high], do: 65535
  defp to_num(i) when is_integer(i) and i >= 0, do: i
  defp to_num({p, delta}), do: to_num(p) + delta

  #

  def dict(pid) do
    info(pid, :dictionary) |> elem(1)
  end

  def inc(key, step \\ +1) do
    put(key, get(key) + step)
  end

  def dec(key, step \\ 1), do: inc(key, -step)

  #

  def value?(pid), do: dict(pid)[:value?]

  def values(workers) do
    for {k, worker} <- workers, v? = value?(worker), into: %{} do
      {k, elem(v?, 0)}
    end
  end

  #

  # handle request in a separate task
  defp spawn_task(r, value?) do
    server = get(:server)
    worker = self()

    Task.start_link(fn ->
      Req.run_and_reply(r, value?)

      if alive?(worker) do
        send(worker, %{info: :done})
      else
        send(server, %{info: :done})
      end
    end)

    inc(:processes)
  end

  # ask server to increase quota
  defp increase_quota() do
    ref = make_ref()

    send(get(:server), {ref, self(), :more?})

    # wait for reply 2 ms

    receive do
      {^ref, msg} ->
        handle(msg)
        :ok
    after
      2 ->
        :error
    end
  end

  ##
  ## get(:value?) → run_and_reply → … commit
  ##

  defp handle(%{act: :get, tiny: true} = r) do
    Req.run_and_reply(r, get(:value?))
  end

  defp handle(%{act: :get} = r) do
    if get(:processes) <= get(:quota) do
      spawn_task(r, get(:value?))
    else
      case increase_quota() do
        :ok ->
          handle(r)

        :error ->
          handle(Map.put(r, :tiny, true))
      end
    end
  end

  defp handle(%{act: act} = r) when act in [:get_upd, :drop] do
    case Req.run_and_reply(r, get(:value?)) do
      {_value} = v? ->
        put(:value?, v?)

      nil ->
        delete(:value?)

      :id ->
        :_ignore
    end
  end

  #

  defp handle(%{info: :done}) do
    dec(:processes)
  end

  defp handle(%{act: :quota, inc: q}) do
    inc(:quota, q)
  end

  # defp handle(%{act: :quota, dec: q}) do
  #   dec(:quota, q)
  # end

  # defp handle(%{act: :quota, set: q}) do
  #   put(:quota, q)
  # end

  #

  defp handle(msg) do
    Logger.warn("""
    Worker #{inspect(self())} got unexpected message.

    Message: #{inspect(msg)}.
    """)
  end

  ##
  ## MAIN
  ##

  def loop({ref, server}, v?, quota) do
    if v?, do: put(:value?, v?)

    send(server, {ref, :resume})

    put(:server, server)
    put(:processes, 0 + 1)
    put(:quota, quota)

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
        send(get(:server), {self(), :die?})

        receive do
          :die! ->
            :bye

          :continue ->
            # next time wait a few ms longer
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

      {_ref, %{act: :quota} = msg} ->
        handle(msg)
        heap

      req ->
        Heap.push(heap, {to_num(req[:!]), -now(), req})
    end
  end
end

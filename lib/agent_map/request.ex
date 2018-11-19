defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Worker, Server, Multi, CallbackError}

  import Worker, only: [spawn_get_task: 2, processes: 1]
  import Server.State

  @compile {:inline, reply_ok: 1}
  @enforce_keys [:act]

  defstruct [
    :act,
    :data,
    :from,
    :key,
    :fun,
    !: 256,
    tiny: false
  ]

  #

  def reply(nil, _msg), do: :nothing
  def reply({_p, _ref} = from, msg), do: GenServer.reply(from, msg)
  def reply(from, msg), do: send(from, msg)

  #

  defp collect(req) do
    case Process.get(:value?) do
      {:v, v} ->
        v

      nil ->
        Map.get(req, :data)
    end
  end

  def run(%{act: :get} = req) do
    arg = collect(req)
    ret = apply(req.fun, [arg])

    req
    |> Map.get(:from)
    |> reply(ret)
  end

  # :get_and_update
  def run(req) do
    arg = collect(req)
    ret = apply(req.fun, [arg])

    from = Map.get(req, :from)

    case ret do
      {get} ->
        reply(from, get)

      {get, v} ->
        Process.put(:value?, {:v, v})
        reply(from, get)

      :id ->
        reply(from, arg)

      :pop ->
        Process.delete(:value?)
        reply(from, arg)

      reply ->
        raise CallbackError, got: reply
    end
  end

  #

  # Compress before sending to worker.
  def compress(%_{} = req) do
    req
    |> Map.from_struct()
    |> compress()
  end

  def compress(map) do
    map
    |> Map.delete(:key)
    |> Map.delete(:keys)
    |> Map.delete(:tiny)
    |> Enum.reject(&match?({_, nil}, &1))
    |> Enum.into(%{})
  end

  #

  defp reply_ok(st), do: {:reply, :_ok, st}

  ##
  ## HANDLER
  ##

  def handle(%{act: :to_map} = req, state) do
    keys = Map.keys(state)

    fun = fn _ -> Process.get(:map) end
    req = struct(Multi.Req, Map.from_struct(req))
    req = %{req | act: :get, fun: fun, keys: keys}

    Multi.Req.handle(req, state)
  end

  def handle(%{act: :processes, key: key}, state) do
    p =
      case get(state, key) do
        {_value?, {p, _max_p}} ->
          p

        worker ->
          processes(worker)
      end

    {:reply, p, state}
  end

  # per key:
  def handle(%{act: :max_processes, key: key, data: nil}, state) do
    max_p =
      case get(state, key) do
        {_, {_, max_p}} ->
          max_p

        worker ->
          Worker.dict(worker)[:max_processes]
      end || Process.get(:max_processes)

    {:reply, max_p, state}
  end

  def handle(%{act: :max_processes, key: key} = req, state) do
    case get(state, key) do
      {box, {p, _max_p}} ->
        state
        |> put(key, {box, {p, req.data}})
        |> reply_ok()

      worker ->
        req = compress(%{req | !: :now, from: nil})
        send(worker, req)
        {:noreply, state}
    end
  end

  #

  def handle(%{act: :keys}, state) do
    has_v? = &match?({:ok, _}, fetch(state, &1))
    keys = Enum.filter(Map.keys(state), has_v?)

    {:reply, keys, state}
  end

  #

  def handle(%{act: :get, key: key, !: :now} = req, state) do
    case get(state, key) do
      {v, {p, max_p}} ->
        spawn_get_task(req, {key, v})
        pack = {v, {p + 1, max_p}}

        {:noreply, put(state, key, pack)}

      w ->
        v = Worker.dict(w)[:value?]
        spawn_get_task(req, {key, v})

        send(w, %{info: :get!})

        {:noreply, state}
    end
  end

  def handle(%{act: :get, key: key} = req, state) do
    g_max_p = Process.get(:max_processes)

    case get(state, key) do
      # Cannot spawn more Task's.
      {_, {p, nil}} when p + 1 >= g_max_p ->
        state = spawn_worker(state, key)
        handle(req, state)

      {_, {p, max_p}} when p + 1 >= max_p ->
        state = spawn_worker(state, key)
        handle(req, state)

      # Can spawn.
      {v, {p, max_p}} ->
        spawn_get_task(req, {key, v})
        pack = {v, {p + 1, max_p}}

        {:noreply, put(state, key, pack)}

      worker ->
        send(worker, compress(req))

        {:noreply, state}
    end
  end

  #

  def handle(%{act: :update, key: key} = req, state) do
    case get(state, key) do
      {v?, info} ->
        if req.tiny do
          Process.put(:key, key)
          Process.put(:value?, v?)

          run(req)

          state =
            case Process.get(:value?) do
              {:v, v} ->
                unless v?, do: Worker.inc(:size)
                put(state, key, {{:v, v}, info})

              nil ->
                if v?, do: Worker.dec(:size)
                put(state, key, {nil, info})
            end

          Process.delete(:key)
          Process.delete(:value?)

          {:noreply, state}
        else
          handle(req, spawn_worker(state, key))
        end

      worker ->
        send(worker, compress(req))
        {:noreply, state}
    end
  end

  #

  def handle(%{act: :fetch, key: key, !: :now}, state) do
    {:reply, fetch(state, key), state}
  end

  def handle(%{act: :fetch, key: key} = req, state) do
    if is_pid(get(state, key)) do
      fun = fn value ->
        if Process.get(:value?) do
          {:ok, value}
        else
          :error
        end
      end

      handle(%{req | act: :get, fun: fun}, state)
    else
      handle(%{req | act: :fetch, !: :now}, state)
    end
  end

  #

  def handle(%{act: :upd_prop, key: key, fun: fun} = req, state) do
    arg = Process.get(key, req.data)
    Process.put(key, apply(IO.inspect(fun), [arg]))
    {:reply, :_ok, state}
  end

  #

  def handle(%{act: :get_prop, key: :processes}, state) do
    ks = Map.keys(state)
    ws = separate(state, ks) |> elem(1)

    ps =
      for {_, pid} <- ws do
        Worker.processes(pid)
      end

    {:reply, Enum.sum(ps) + 1, state}
  end

  def handle(%{act: :get_prop, key: key} = req, state) do
    prop = Process.get(key, req.data)
    {:reply, prop, state}
  end
end

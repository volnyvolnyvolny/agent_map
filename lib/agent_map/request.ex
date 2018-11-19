defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Worker, Server, Multi}

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
    !: 256
  ]

  #

  def compress(%_{} = req) do
    req
    |> Map.from_struct()
    |> compress()
  end

  def compress(map) do
    map
    |> Map.delete(:key)
    |> Map.delete(:keys)
    |> Enum.reject(&match?({_, nil}, &1))
    |> Enum.into(%{})
  end

  #

  def get_and_update(req, fun) do
    %{req | act: :get_and_update, fun: fun, data: nil}
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

  def handle(%{act: :inc, key: key} = req, state) do
    step = req.data[:step]

    i = req.data[:initial]

    inc = fn
      {:value, v} when is_number(v) ->
        v + step

      {:value, v} ->
        k = inspect(key)
        v = inspect(v)

        m = &"cannot #{&1}rement key #{k} because it has a non-numerical value #{v}"
        m = m.((step > 0 && "inc") || "dec")

        raise ArithmeticError, message: m

      nil ->
        if i, do: i + step, else: raise(KeyError, key: key)
    end

    case get(state, key) do
      {v, _info} = old ->
        state
        |> put_value(key, inc.(v), old)
        |> reply_ok()

      _worker ->
        req
        |> get_and_update(fn _value ->
          {:_ok, inc.(Process.get(:value))}
        end)
        |> handle(state)
    end
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

  # per server:
  def handle(%{act: :def_max_processes} = req, state) do
    Process.put(:max_processes, req.data)

    reply_ok(state)
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
        v = Worker.dict(w)[:value]
        spawn_get_task(req, {key, v})

        send(w, %{info: :get!})
        {:noreply, state}
    end
  end

  def handle(%{act: :get, key: key} = req, state = st) do
    g_max_p = Process.get(:max_processes)

    case get(st, key) do
      # Cannot spawn more Task's.
      {_, {p, nil}} when p + 1 >= g_max_p ->
        handle(req, spawn_worker(st, key))

      {_, {p, max_p}} when p + 1 >= max_p ->
        handle(req, spawn_worker(st, key))

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

  def handle(%{act: :get_and_update, key: key} = req, state = st) do
    case get(state, key) do
      {_box, _info} ->
        handle(req, spawn_worker(st, key))

      worker ->
        send(worker, compress(req))
        {:noreply, state}
    end
  end

  #

  def handle(%{act: :put, key: key} = req, state) do
    case get(state, key) do
      {_, _} = old ->
        state
        |> put_value(key, req.data, old)
        |> reply_ok()

      worker ->
        req =
          get_and_update(req, fn _ ->
            {:ok, req.data}
          end)

        send(worker, compress(req))

        {:noreply, state}
    end
  end

  def handle(%{act: :put_new, key: key} = req, state = st) do
    case get(state, key) do
      {nil, _} = old ->
        if req.fun do
          handle(req, spawn_worker(st, key))
        else
          st
          |> put_value(key, req.data, old)
          |> reply_ok()
        end

      {_, _} ->
        reply_ok(state)

      worker ->
        req =
          get_and_update(req, fn _ ->
            unless Process.get(:value) do
              fun = req.fun
              {:_ok, (fun && fun.()) || req.data}
            end || {:_ok}
          end)

        send(worker, compress(req))
        {:noreply, state}
    end
  end

  #

  def handle(%{act: :fetch, key: key, !: :now}, _state = st) do
    {:reply, fetch(st, key), st}
  end

  def handle(%{act: :fetch, key: key} = req, state = st) do
    if is_pid(get(state, key)) do
      fun = fn value ->
        if Process.get(:value) do
          {:ok, value}
        else
          :error
        end
      end

      handle(%{req | act: :get, fun: fun}, st)
    else
      handle(%{req | act: :fetch, !: :now}, st)
    end
  end

  #

  def handle(%{act: :delete, key: key} = req, state) do
    case get(state, key) do
      {value, info} ->
        if value, do: Worker.dec(:size)

        state
        |> put(key, {nil, info})
        |> reply_ok()

      _worker ->
        req
        |> get_and_update(fn _ -> :pop end)
        |> handle(state)
    end
  end

  #

  def handle(%{act: :sleep} = req, state) do
    fun = fn _ ->
      :timer.sleep(req.data)
      :id
    end

    req
    |> get_and_update(fun)
    |> handle(state)
  end

  #

  def handle(%{act: :get_prop, key: :size}, state) do
    {:reply, Process.get(:size), state}
  end

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

  def handle(%{act: :set_prop, key: key} = req, state) do
    Process.put(key, req.data)
    {:noreply, state}
  end
end

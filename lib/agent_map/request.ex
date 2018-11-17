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

  def handle(%{act: :to_map} = req, st) do
    keys = Map.keys(st)

    fun = fn _ -> Process.get(:map) end
    req = struct(Multi.Req, Map.from_struct(req))
    req = %{req | act: :get, fun: fun, keys: keys}

    Multi.Req.handle(req, st)
  end

  def handle(%{act: :inc, key: key} = req, st) do
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

    case get(st, key) do
      {v, _info} = old ->
        st
        |> put_value(key, inc.(v), old)
        |> reply_ok()

      _worker ->
        req
        |> get_and_update(fn _value ->
          {:_ok, inc.(Process.get(:value))}
        end)
        |> handle(st)
    end
  end

  def handle(%{act: :processes, key: key}, st) do
    p =
      case get(st, key) do
        {_box, {p, _max_p}} ->
          p

        worker ->
          processes(worker)
      end

    {:reply, p, st}
  end

  # per key:
  def handle(%{act: :max_processes, key: key, data: nil}, st) do
    max_p =
      case get(st, key) do
        {_, {_, max_p}} ->
          max_p

        worker ->
          Worker.dict(worker)[:max_processes]
      end || Process.get(:max_processes)

    {:reply, max_p, st}
  end

  def handle(%{act: :max_processes, key: key} = req, st) do
    case get(st, key) do
      {box, {p, _max_p}} ->
        st
        |> put(key, {box, {p, req.data}})
        |> reply_ok()

      worker ->
        req = compress(%{req | !: :now, from: nil})
        send(worker, req)
        {:noreply, st}
    end
  end

  # per server:
  def handle(%{act: :def_max_processes} = req, st) do
    Process.put(:max_processes, req.data)

    reply_ok(st)
  end

  #

  def handle(%{act: :keys}, st) do
    has_v? = &match?({:ok, _}, fetch(st, &1))
    keys = Enum.filter(Map.keys(st), has_v?)

    {:reply, keys, st}
  end

  #

  def handle(%{act: :get, key: key, !: :now} = req, st) do
    case get(st, key) do
      {v, {p, max_p}} ->
        spawn_get_task(req, {key, v})
        pack = {v, {p + 1, max_p}}

        {:noreply, put(st, key, pack)}

      w ->
        v = Worker.dict(w)[:value]
        spawn_get_task(req, {key, v})

        send(w, %{info: :get!})
        {:noreply, st}
    end
  end

  def handle(%{act: :get, key: key} = req, st) do
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

        {:noreply, put(st, key, pack)}

      worker ->
        send(worker, compress(req))
        {:noreply, st}
    end
  end

  #

  def handle(%{act: :get_and_update, key: key} = req, st) do
    case get(st, key) do
      {_box, _info} ->
        handle(req, spawn_worker(st, key))

      worker ->
        send(worker, compress(req))
        {:noreply, st}
    end
  end

  #

  def handle(%{act: :put, key: key} = req, st) do
    case get(st, key) do
      {_, _} = old ->
        st
        |> put_value(key, req.data, old)
        |> reply_ok()

      worker ->
        req =
          get_and_update(req, fn _ ->
            {:ok, req.data}
          end)

        send(worker, compress(req))

        {:noreply, st}
    end
  end

  def handle(%{act: :put_new, key: key} = req, st) do
    case get(st, key) do
      {nil, _} = old ->
        if req.fun do
          handle(req, spawn_worker(st, key))
        else
          st
          |> put_value(key, req.data, old)
          |> reply_ok()
        end

      {_, _} ->
        reply_ok(st)

      worker ->
        req =
          get_and_update(req, fn _ ->
            unless Process.get(:value) do
              fun = req.fun
              {:_ok, (fun && fun.()) || req.data}
            end || {:_ok}
          end)

        send(worker, compress(req))
        {:noreply, st}
    end
  end

  #

  def handle(%{act: :fetch, key: key, !: :now}, st) do
    {:reply, fetch(st, key), st}
  end

  def handle(%{act: :fetch, key: key} = req, st) do
    if is_pid(get(st, key)) do
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

  def handle(%{act: :delete, key: key} = req, st) do
    case get(st, key) do
      {value, info} ->
        if value, do: Worker.dec(:size)

        st
        |> put(key, {nil, info})
        |> reply_ok()

      _worker ->
        req
        |> get_and_update(fn _ -> :pop end)
        |> handle(st)
    end
  end

  #

  def handle(%{act: :sleep} = req, st) do
    fun = fn _ ->
      :timer.sleep(req.data)
      :id
    end

    req
    |> get_and_update(fun)
    |> handle(st)
  end

  #

  def handle(%{act: :get_prop, key: :size}, st) do
    # has_v? = &match?({:ok, _}, fetch(state, &1))
    # size = Enum.count(Map.keys(state), has_v?)

    {:reply, Process.get(:size), st}
  end

  def handle(%{act: :get_prop, key: :processes}, st) do
    ws = separate(st, Map.keys(st)) |> elem(1)

    ps =
      for {_, pid} <- ws do
        Worker.processes(pid)
      end

    {:reply, Enum.sum(ps) + 1, st}
  end

  def handle(%{act: :get_prop, key: key} = req, st) do
    prop = Process.get(key, req.data)
    {:reply, prop, st}
  end

  def handle(%{act: :set_prop, key: key} = req, st) do
    Process.put(key, req.data)
    {:noreply, st}
  end
end

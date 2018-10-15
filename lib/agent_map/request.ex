defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Worker, Req, Server, Common, Multi}

  import Worker, only: [spawn_get_task: 2, processes: 1]
  import Enum, only: [filter: 2]
  import Server.State
  import Common

  @enforce_keys [:action]

  defstruct [
    :action,
    :data,
    :from,
    :key,
    :fun,
    :inserted_at,
    timeout: 5000,
    !: 256
  ]

  def timeout(%_{timeout: {:!, t}, inserted_at: nil}), do: t
  def timeout(%_{timeout: t, inserted_at: nil}), do: t

  def timeout(%_{} = r) do
    timeout(%{r | inserted_at: nil})
    |> left(since: r.inserted_at)
  end

  def compress(%Req{} = req) do
    req
    |> Map.from_struct()
    |> Map.delete(:key)
    |> Map.delete(:keys)
    |> compress()
  end

  def compress(%{inserted_at: nil} = map) do
    map
    |> Map.delete(:inserted_at)
    |> Map.delete(:timeout)
    |> compress()
  end

  def compress(map) do
    map
    |> Enum.reject(&match?({_, nil}, &1))
    |> Enum.into(%{})
  end

  defp get_and_update(req, fun) do
    %{req | action: :get_and_update, fun: fun, data: nil}
  end

  ##
  ## HANDLERS
  ##

  def handle(%Req{action: :to_map} = req, state) do
    keys = Map.keys(state)
    fun = fn _ -> Process.get(:map) end

    req = struct(Multi.Req, Map.from_struct(req))

    req = %{req | action: :get, fun: fun, keys: keys}

    Multi.Req.handle(req, state)
  end

  def handle(%Req{action: :inc} = req, state) do
    key = req.key
    step = req.data[:step]
    safe? = req.data[:safe]
    initial = req.data[:initial]

    req
    |> get_and_update(fn
      v when is_number(v) ->
        {:ok, v + step}

      v ->
        res =
          if Process.get(:value) do
            k = Process.get(:key) |> inspect()
            v = inspect(v)
            m = &"cannot #{&1}rement key #{k} because it has a non-numerical value #{v}"

            %ArithmeticError{message: m.((step > 0 && "inc") || "dec")}
          else
            # no value:
            if initial do
              initial + step
            else
              %KeyError{key: key}
            end
          end

        case res do
          v when is_number(v) ->
            {:ok, v}

          e ->
            if safe? do
              Logger.error(Exception.message(e))

              {{:error, e}}
            else
              raise e
            end
        end
    end)
    |> handle(state)
  end

  def handle(%Multi.Req{action: :drop, from: nil} = req, state) do
    req =
      Req
      |> struct(req)
      |> Map.put(:action, :delete)

    state =
      Enum.reduce(req.keys, state, fn key, state ->
        case handle(%{req | key: key}, state) do
          {:reply, _, state} ->
            state

          {:noreply, state} ->
            state
        end
      end)

    {:reply, :_ok, state}
  end

  def handle(%Multi.Req{action: :drop} = req, state) do
    {_map, workers} = separate(state, req.keys)

    keys = req.keys -- Map.keys(workers)

    {:reply, _, state} = handle(%{req | from: nil, keys: keys}, state)

    if keys != [] do
      pids = Map.values(workers)

      server = self()
      ref = make_ref()

      Task.start_link(fn ->
        req =
          %{req | from: self()}
          |> get_and_update(fn _ -> :pop end)

        Worker.broadcast(pids, compress(req))
        send(server, {ref, :go!})

        Worker.collect(pids, timeout(req))
      end)

      receive do
        {^ref, :go!} ->
          {:noreply, state}
      end
    else
      {:reply, :_ok, state}
    end
  end

  def handle(%Req{action: :processes} = req, state) do
    p =
      case get(state, req.key) do
        {_box, {p, _max_p}} ->
          p

        worker ->
          processes(worker)
      end

    {:reply, p, state}
  end

  # per key:
  def handle(%Req{action: :max_processes, key: {key}, data: nil}, state) do
    max_p =
      case get(state, key) do
        {_box, {_p, max_p}} ->
          max_p

        worker ->
          Worker.dict(worker)[:max_processes]
      end || Process.get(:max_processes)

    {:reply, max_p, state}
  end

  def handle(%Req{action: :max_processes, key: {key}} = req, state) do
    state =
      case get(state, key) do
        {box, {p, _max_p}} ->
          pack = {box, {p, req.data}}
          put(state, key, pack)

        worker ->
          req = compress(%{req | !: :now, from: nil})
          send(worker, req)
      end

    {:noreply, state}
  end

  # per server:
  def handle(%Req{action: :max_processes} = req, state) do
    max_p = Process.put(:max_processes, req.data)
    {:reply, max_p, state}
  end

  #

  def handle(%Req{action: :keys}, state) do
    has_value? = &match?({:ok, _}, fetch(state, &1))
    ks = filter(Map.keys(state), has_value?)

    {:reply, ks, state}
  end

  #

  def handle(%Req{action: :get, !: :now} = req, state) do
    case get(state, req.key) do
      {b, {p, max_p}} ->
        spawn_get_task(req, {req.key, b})

        pack = {b, {p + 1, max_p}}
        state = put(state, req.key, pack)
        {:noreply, state}

      w ->
        b = Worker.dict(w)[:value]
        spawn_get_task(req, {req.key, b})

        send(w, %{info: :get!})
        {:noreply, state}
    end
  end

  def handle(%Req{action: :get} = req, state) do
    g_max_p = Process.get(:max_processes)

    case get(state, req.key) do
      # Cannot spawn more Task's.
      {_, {p, nil}} when p >= g_max_p ->
        state = spawn_worker(state, req.key)
        handle(req, state)

      {_, {p, max_p}} when p >= max_p ->
        state = spawn_worker(state, req.key)
        handle(req, state)

      # Can spawn.
      {b, {p, max_p}} ->
        spawn_get_task(req, {req.key, b})
        pack = {b, {p + 1, max_p}}
        state = put(state, req.key, pack)
        {:noreply, state}

      worker ->
        send(worker, compress(req))
        {:noreply, state}
    end
  end

  #

  def handle(%Req{action: :get_and_update} = req, state) do
    case get(state, req.key) do
      {_box, _p_info} ->
        state = spawn_worker(state, req.key)
        handle(req, state)

      worker ->
        send(worker, compress(req))
        {:noreply, state}
    end
  end

  #

  def handle(%Req{action: :put} = req, state) do
    case get(state, req.key) do
      {_box, p_info} ->
        pack = {box(req.data), p_info}
        {:reply, :ok, put(state, req.key, pack)}

      worker ->
        req =
          get_and_update(req, fn _ ->
            {:ok, req.data}
          end)

        send(worker, compress(req))
        {:noreply, state}
    end
  end

  def handle(%Req{action: :put_new} = req, state) do
    case get(state, req.key) do
      {nil, p_info} ->
        if req.fun do
          state = spawn_worker(state, req.key)
          handle(req, state)
        else
          pack = {box(req.data), p_info}
          {:reply, :_ok, put(state, req.key, pack)}
        end

      {_box, _p_info} ->
        {:reply, :_ok, state}

      worker ->
        req =
          get_and_update(req, fn _ ->
            unless Process.get(:value) do
              if req.fun do
                {:_ok, req.fun.()}
              else
                {:_ok, req.data}
              end
            end || {:_ok}
          end)

        send(worker, compress(req))
        {:noreply, state}
    end
  end

  def handle(%Req{action: :fetch, !: :now} = req, state) do
    value = fetch(state, req.key)
    {:reply, value, state}
  end

  def handle(%Req{action: :fetch} = req, state) do
    fun = fn value ->
      if Process.get(:value) do
        {:ok, value}
      else
        :error
      end
    end

    handle(%{req | action: :get, fun: fun}, state)
  end

  def handle(%Req{action: :delete} = req, state) do
    case get(state, req.key) do
      {_box, p_info} ->
        pack = {nil, p_info}
        state = put(state, req.key, pack)
        {:reply, :done, state}

      _worker ->
        req
        |> get_and_update(fun: fn _ -> :pop end)
        |> handle(state)
    end
  end

  def handle(%Req{action: :sleep} = req, state) do
    req
    |> get_and_update(fn _ ->
      :timer.sleep(req.data)
      :id
    end)
    |> handle(state)
  end
end

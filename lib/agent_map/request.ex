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

  #

  def timeout(%{timeout: {:!, t}, inserted_at: nil}), do: t
  def timeout(%{timeout: t, inserted_at: nil}), do: t

  def timeout(%{} = r) do
    timeout(%{r | inserted_at: nil})
    |> left(since: r.inserted_at)
  end

  #

  def compress(%_{} = req) do
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

  #

  def get_and_update(req, fun) do
    %{req | action: :get_and_update, fun: fun, data: nil}
  end

  ##
  ## HANDLERS
  ##

  def handle(%{action: :to_map} = req, state) do
    keys = Map.keys(state)
    fun = fn _ -> Process.get(:map) end

    req = struct(Multi.Req, Map.from_struct(req))

    req = %{req | action: :get, fun: fun, keys: keys}

    Multi.Req.handle(req, state)
  end

  def handle(%{action: :inc} = req, state) do
    step = req.data[:step]
    safe? = req.data[:safe]

    k = req.key
    i = req.data[:initial]

    req
    |> get_and_update(fn
      v when is_number(v) ->
        {:ok, v + step}

      v ->
        res =
          if Process.get(:value) do
            k = inspect(k)
            v = inspect(v)

            m = &"cannot #{&1}rement key #{k} because it has a non-numerical value #{v}"
            m = m.((step > 0 && "inc") || "dec")

            %ArithmeticError{message: m}
          else
            if i, do: i + step, else: %KeyError{key: k}
          end

        case res do
          v when is_number(v) ->
            {:ok, v}

          e ->
            if safe? do
              unless req.from do
                # case: true
                Logger.error(Exception.message(e))
              end

              {{:error, e}}
            else
              raise e
            end
        end
    end)
    |> handle(state)
  end

  def handle(%{action: :processes} = req, state) do
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
  def handle(%{action: :max_processes, data: nil} = req, state) do
    max_p =
      case get(state, req.key) do
        {_box, {_p, max_p}} ->
          max_p

        worker ->
          Worker.dict(worker)[:max_processes]
      end || Process.get(:max_processes)

    {:reply, max_p, state}
  end

  def handle(%{action: :max_processes} = req, state) do
    case get(state, req.key) do
      {box, {p, _max_p}} ->
        pack = {box, {p, req.data}}
        {:reply, :_ok, put(state, req.key, pack)}

      worker ->
        req = compress(%{req | !: :now, from: nil})
        send(worker, req)
        {:noreply, state}
    end
  end

  # per server:
  def handle(%{action: :def_max_processes} = req, state) do
    Process.put(:max_processes, req.data)
    {:reply, :_ok, state}
  end

  #

  def handle(%{action: :keys}, state) do
    has_value? = &match?({:ok, _}, fetch(state, &1))
    ks = filter(Map.keys(state), has_value?)

    {:reply, ks, state}
  end

  #

  def handle(%{action: :get, !: :now} = req, state) do
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

  def handle(%{action: :get} = req, state) do
    g_max_p = Process.get(:max_processes)

    case get(state, req.key) do
      # Cannot spawn more Task's.
      {_, {p, nil}} when p + 1 >= g_max_p ->
        state = spawn_worker(state, req.key)
        handle(req, state)

      {_, {p, max_p}} when p + 1 >= max_p ->
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

  def handle(%{action: :get_and_update} = req, state) do
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

  def handle(%{action: :put} = req, state) do
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

  def handle(%{action: :put_new} = req, state) do
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

  def handle(%{action: :fetch, !: :now} = req, state) do
    value = fetch(state, req.key)
    {:reply, value, state}
  end

  def handle(%{action: :fetch} = req, state) do
    if is_pid(get(state, req.key)) do
      fun = fn value ->
        if Process.get(:value) do
          {:ok, value}
        else
          :error
        end
      end

      handle(%{req | action: :get, fun: fun}, state)
    else
      handle(%{req | action: :fetch, !: :now}, state)
    end
  end

  def handle(%{action: :delete} = req, state) do
    case get(state, req.key) do
      {_box, p_info} ->
        pack = {nil, p_info}
        state = put(state, req.key, pack)
        {:reply, :done, state}

      _worker ->
        req
        |> get_and_update(fn _ -> :pop end)
        |> handle(state)
    end
  end

  def handle(%{action: :sleep} = req, state) do
    req
    |> get_and_update(fn _ ->
      :timer.sleep(req.data)
      :id
    end)
    |> handle(state)
  end
end

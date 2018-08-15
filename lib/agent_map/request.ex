defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Common, Worker, Transaction, Req}

  import Process, only: [get: 1, put: 2, info: 1]
  import Worker, only: [unbox: 1, queue: 1]
  import Common, only: [reply: 2, dict: 1]

  @enforce_keys [:action]

  # action: :get, :get_and_update, :update, :cast, :keys, …
  # data: {key, fun}, {fun, keys}, …
  # from: nil | GenServer.from
  # timeout: timeout | {:drop | :break, timeout}
  defstruct [
    :action,
    :data,
    :from,
    :inserted_at,
    timeout: 5000,
    !: false
  ]

  def get_state({:reply, _r, state}), do: state
  def get_state({:noreply, state}), do: state

  ##
  ## BOXING
  ##

  def box(value, p, custom_max_p, max_p)

  def box(value, 0, max_p, max_p), do: value
  def box(value, p, max_p, max_p), do: {value, p}
  def box(value, p, max_p, _), do: {value, {p, max_p}}

  ##
  ## STATE CHANGING
  ##

  defp pack(key, value, {p, custom_max_p}, {map, max_p}) do
    case box(value, p, custom_max_p, max_p) do
      nil ->
        {Map.delete(map, key), max_p}

      box ->
        {%{map | key => box}, max_p}
    end
  end

  defp unpack(key, {map, max_p}) do
    case map[key] do
      {:pid, worker} ->
        {:pid, worker}

      {_value, {_p, _custom_max_p}} = box ->
        box

      {value, p} ->
        {value, {p, max_p}}

      value ->
        {value, {0, max_p}}
    end
  end

  def spawn_worker(key, state) do
    {map, max_p} = state

    unless match?({:pid, _}, map[key]) do
      ref = make_ref()

      worker =
        spawn_link(fn ->
          Worker.loop({ref, self()}, key, unpack(key, state))
        end)

      receive do
        {^ref, _} ->
          :continue
      end

      {%{map | key => {:pid, worker}}, max_p}
    end || state
  end

  ##
  ## MESSAGES TO WORKER
  ##

  defp as_map(%{data: {_key, f}} = req) do
    req
    |> Map.from_struct()
    |> Map.delete(:data)
    |> Map.put(:fun, f)
  end

  defp get_and_update(req, fun) do
    as_map(%{req | action: :get_and_update, data: {:_, fun}})
  end

  ##
  ## FETCH
  ##

  def get_value(key, state) do
    case unpack(key, state) do
      {:pid, worker} ->
        dict(worker)[:"$value"]

      {value, _} ->
        value
    end
  end

  defp fetch(key, state) do
    case get_value(key, state) do
      {:value, v} ->
        {:ok, v}

      nil ->
        :error
    end
  end

  defp has_key?(key, state) do
    match?({:ok, _}, fetch(key, state))
  end

  ##
  ## HELPERS
  ##

  defp run(%{action: :get} = req, value) do
    {key, fun} = req.data

    put(:"$key", key)
    put(:"$value", value)

    case Common.run(req, [unbox(value)]) do
      {:ok, msg} ->
        reply(req.from, msg)

      {:error, :expired} ->
        :ignore
    end
  end

  ##
  ## HANDLERS
  ##

  def handle(%{action: :inc} = req, {map, max_p} = state) do
    {key, initial, step} = req.data

    case unpack(key, state) do
      {:pid, worker} ->
        fun = fn
          v when is_number(v) ->
            {:ok, v + step}

          v ->
            if Process.get(:"$value") do
              raise IncError, key: key, value: v, step: step
            else
              if initial do
                {:ok, initial + step}
              else
                raise KeyError, key: key
              end
            end
        end

        send(worker, get_and_update(req, fun))
        {:noreply, state}

      {{:value, v}, _} when not is_number(v) ->
        raise IncError, key: key, value: v, step: step

      {nil, _} when not is_number(initial) ->
        raise KeyError, key: key

      {{:value, v}, p_info} ->
        value = {:value, v + step}
        state = pack(key, value, p_info, state)
        {:reply, :ok, state}

      {nil, p_info} ->
        value = {:value, initial + step}
        state = pack(key, value, p_info, state)
        {:reply, :ok, state}
    end
  end

  def handle(%{action: :queue_len} = req, {map, _} = state) do
    {key, opts} = req.data

    num =
      case map[key] do
        {:pid, worker} ->
          worker
          |> queue()
          |> Enum.count(fn msg ->
            not match?(%{info: _}, msg) &&
              case opts do
                [!: true] ->
                  msg[:!]

                [!: false] ->
                  not msg[:!]

                _ ->
                  true
              end
          end)

        _ ->
          0
      end

    {:reply, num, state}
  end

  def handle(%{action: :drop, data: keys} = req, state) do
    state =
      Enum.reduce(keys, state, fn key, state ->
        %{req | action: :delete, data: key}
        |> handle(state)
        |> get_state()
      end)

    {:noreply, state}
  end

  def handle(%{action: :keys}, {map, _} = state) do
    keys = Enum.filter(Map.keys(map), &has_key?(&1, state))

    {:reply, keys, state}
  end

  def handle(%{action: :values} = req, {map, _} = state) do
    fun = fn _ ->
      Map.values(get(:"$map"))
    end

    handle(%{req | action: :get, data: {fun, Map.keys(map)}}, state)
  end

  def handle(%{action: :delete, data: key} = req, {map, max_p} = state) do
    case unpack(key, state) do
      {:pid, worker} ->
        fun = fn _ -> :drop end
        send(worker, get_and_update(req, fun))

        {:noreply, state}

      {_, {0, ^max_p}} ->
        map = Map.delete(map, key)
        {:reply, :ok, {map, max_p}}

      {value, p_info} ->
        state = pack(key, value, p_info, state)
        {:reply, :ok, state}
    end
  end

  def handle(%{action: :max_processes, data: max_processes} = req, {map, old_one}) do
    {:reply, old_one, {map, max_processes}}
  end

  def handle(%{action: :max_processes} = req, {map, max_p} = state) do
    {key, new_max_p} = req.data

    case unpack(key, state) do
      {:pid, worker} ->
        send(worker, %{req | data: new_max_p})
        {:noreply, state}

      {value, {p, old_max_p}} ->
        state = pack(key, value, {p, new_max_p}, state)
        {:reply, old_max_p, state}
    end
  end

  def handle(%{action: :fetch, data: key} = req, {map, _} = state) do
    if req.! do
      {:reply, fetch(map, key), state}
    else
      fun = fn _ ->
        case get(:"$value") do
          {:value, v} ->
            {:ok, v}

          nil ->
            :error
        end
      end

      handle(%Req{action: :get, data: {key, fun}}, state)
    end
  end

  # Any transaction.
  def handle(%{data: {_fun, keys}} = req, map) when is_list(keys) do
    Transaction.handle(req, map)
  end

  def handle(%{action: :get, !: true} = req, {map, _max_p} = state) do
    {key, fun} = req.data

    v = get_value(key, state)

    Task.start_link(fn ->
      run(req, v)
    end)

    {:noreply, state}
  end

  def handle(%{action: :get, !: false} = req, {map, max_p} = state) do
    {key, fun} = req.data

    case unpack(key, state) do
      {:pid, worker} ->
        send(worker, as_map(req))

      # Cannot spawn more Task's.
      {_, {p, p}} ->
        state = spawn_worker(key, state)
        handle(req, state)

      # Can spawn.
      {v, {p, custom_max_p}} ->
        server = self()
        Task.start_link(fn ->
          run(req, v)
          send(server, %{info: :done, !: true})
        end)

        state = pack(key, v, {p + 1, custom_max_p}, state)
        {:noreply, state}
    end
  end

  def handle(%{action: :put} = req, {map, max_p} = state) do
    {key, value} = req.data

    case unpack(key, state) do
      {:pid, worker} ->
        fun = fn _ -> {:ok, value} end
        send(worker, get_and_update(req, fun))
        {:noreply, state}

      {_old_value, p_info} ->
        value = {:value, value}
        state = pack(key, value, p_info, state)
        {:reply, :ok, state}
    end
  end

  def handle(%{action: :pop} = req, {map, max_p} = state) do
    {key, default} = req.data

    case unpack(key, state) do
      {:pid, worker} ->
        fun = fn _ ->
          case Process.get(:"$value") do
            nil ->
              {default}

            _ ->
              :pop
          end
        end

        send(worker, get_and_update(req, fun))

        {:noreply, map}

      {{:value, v}, p_info} ->
        state = pack(key, nil, p_info, state)
        {:reply, v, state}

      {nil, _p} ->
        {:reply, default, state}
    end
  end

  # :get_and_update
  def handle(%{action: :get_and_update} = req, {map, max_p} = state) do
    {key, _} = req.data

    case map[key] do
      {:pid, worker} ->
        send(worker, as_map(req))
        {:noreply, state}

      _ ->
        handle(req, spawn_worker(key, state))
    end
  end
end

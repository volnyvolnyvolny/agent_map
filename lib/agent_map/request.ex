defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Common, Worker, Transaction, Req}

  import Worker, only: [queue: 1, dict: 1]
  import Common, only: [unbox: 1, run: 2, handle_timeout_error: 1]

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

  ##
  ## MESSAGES TO WORKER
  ##

  defp get(req, fun) do
    req =
      req
      |> Map.from_struct()
      |> Map.delete(:data)

    %{req | action: :get, fun: fun}
  end

  defp get_and_update(req, fun) do
    req =
      req
      |> Map.from_struct()
      |> Map.delete(:data)

    %{req | action: :get_and_update, fun: fun}
  end

  ##
  ## FETCH
  ##

  def get_value(key, state) do
    case unpack(key, state) do
      {:pid, worker} ->
        dict(worker)[:"$value"]

      {value, _, _} ->
        value
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
        state = pack(key, initial, p_info, state)
        handle(req, state)
    end
  end

  def handle(%{action: :queue_len} = req, {map, _} = state) do
    {key, opts} = req.data

    num =
      case map[key] do
        {:pid, worker} ->
          worker
          |> queue()
          |> Enum.count(fn
            %{info: _} ->
              false

            msg ->
              # XNOR :)
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

  def handle(%{action: :keys}, {map, _} = state) do
    keys = Enum.filter(Map.keys(map), &get_value(&1, state))

    {:reply, keys, state}
  end

  def handle(%{action: :values} = req, {map, _} = state) do
    fun = fn _ ->
      Map.values(Process.get(:"$map"))
    end

    handle(%{req | action: :get, data: {fun, Map.keys(map)}}, state)
  end

  def handle(%{action: :delete, data: key} = req, {map, max_p} = state) do
    case unpack(key, state) do
      {:pid, worker} ->
        fun = fn _ -> :drop end
        send(worker, get_and_update(req, fun))

        {:noreply, state}

      {_, p_info} ->
        state = pack(key, nil, p_info, state)
        {:reply, :ok, state}
    end
  end

  def handle(%{action: :max_processes, data: {key, new_max_p}} = req, state) do
    case unpack(key, state) do
      {:pid, worker} ->
        send(worker, %{req | data: new_max_p})
        {:noreply, state}

      {value, {p, old_max_p}} ->
        state = pack(key, value, {p, new_max_p}, state)
        {:reply, old_max_p, state}
    end
  end

  def handle(%{action: :max_processes, data: max_processes} = req, {map, old_one}) do
    {:reply, old_one, {map, max_processes}}
  end

  def handle(%{action: :fetch, data: key} = req, {map, _} = state) do
    if req.! do
      case get_value(key, state) do
        {:value, v} ->
          {:reply, {:ok, v}}

        nil ->
          {:reply, :error}
      end
    else
      fun = fn _ ->
        case Process.get(:"$value") do
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
    {k, fun} = req.data

    v = get_value(key, state)

    Task.start_link(fn ->
      Process.put(:"$key", k)
      Process.put(:"$value", v)

      case run(req, v) do
        {:ok, get} ->
          GenServer.reply(req.from, get)

        {:error, :expired} ->
          handle_timeout_error(req)
      end
    end)

    {:noreply, state}
  end

  def handle(%{action: :get, !: false} = req, {map, max_p} = state) do
    {k, fun} = req.data

    case unpack(key, state) do
      {:pid, worker} ->
        send(worker, to_map(req))

      # Cannot spawn more Task's.
      {_, {p, p}} ->
        state = spawn_worker(key, state)
        handle(req, state)

      # Can spawn.
      {v, {p, custom_max_p}} ->
        server = self()

        Task.start_link(fn ->
          Process.put(:"$key", k)
          Process.put(:"$value", v)

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
        msg =
          get_and_update(req, fn value ->
            {:ok, value}
          end)

        send(worker, msg)
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
        send(worker, to_map(req))
        {:noreply, state}

      _ ->
        handle(req, spawn_worker(key, state))
    end
  end
end

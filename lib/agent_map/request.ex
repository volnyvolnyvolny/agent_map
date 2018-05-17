defmodule AgentMap.Req do
  @moduledoc false

  alias AgentMap.{Callback, Worker, Transaction, Req}

  @max_threads 5

  # action: :get, :get_and_update, :update, :cast, :keys, …
  # data: {key, fun}, {fun, keys}, …
  # from: pid
  # !(urgent): true | false
  defstruct [
    :action,
    :data,
    from: self(),
    !: false
  ]

  def to_msg(%Req{!: true} = req) do
    {:!, to_msg(%{req | !: false})}
  end

  def to_msg(%Req{data: {_, fun}, action: :cast}), do: {:cast, fun}

  def to_msg(%Req{data: {_, fun}} = req) do
    {req.action, fun, req.from}
  end

  def spawn_worker(map, key) do
    worker = spawn_link(Worker, :loop, [self(), key, map[key]])
    put_in(map[key], {:pid, worker})
  end

  def fetch(map, key) do
    case map[key] do
      {:pid, worker} ->
        {_, dict} = Process.info(worker, :dictionary)

        case dict[:"$value"] do
          nil -> fetch(map, key)
          :no -> :error
          {:value, value} -> {:ok, value}
        end

      {{:value, value}, _} ->
        {:ok, value}

      {nil, _} ->
        :error

      nil ->
        :error
    end
  end

  ##
  ## HELPERS
  ##

  defp has_key?(map, key) do
    match?({:ok, _}, fetch(map, key))
  end

  defp unbox(nil), do: nil
  defp unbox({:value, value}), do: value

  ##
  ## HANDLERS
  ##

  def handle(%Req{action: :keys}, map) do
    keys =
      map
      |> Map.keys()
      |> Enum.filter(&has_key?(map, &1))

    {:reply, keys, map}
  end

  def handle(%Req{action: :queue_len, data: key}, map) do
    case map[key] do
      {:pid, worker} ->
        {_, queue} = Process.info(worker, :messages)

        num =
          Enum.count(queue, fn msg ->
            msg not in [:done, :done_on_server]
          end)

        {:reply, num, map}

      _ ->
        {:reply, 0, map}
    end
  end

  def handle(%Req{action: :take, data: keys}, map) do
    res =
      Enum.reduce(keys, %{}, fn key, res ->
        case fetch(map, key) do
          {:ok, value} -> put_in(res[key], value)
          _ -> res
        end
      end)

    {:reply, res, map}
  end

  def handle(%Req{action: :drop, data: keys, !: urgent}, map) do
    map =
      Enum.reduce(keys, map, fn key, map ->
        {_, map} =
          handle(
            %Req{action: :delete, data: key, !: urgent},
            map
          )

        map
      end)

    {:noreply, map}
  end

  def handle(%Req{action: :delete, data: key} = req, map) do
    case map[key] do
      {:pid, worker} ->
        if req[:urgent] do
          send(worker, {:!, :drop})
        else
          send(worker, :drop)
        end

        {:noreply, map}

      {{:value, _}, @max_threads} ->
        {:noreply, Map.delete(map, key)}

      {{:value, _}, mt} ->
        {:noreply, put_in(map[key], {nil, mt})}

      {nil, _} ->
        {:noreply, map}

      nil ->
        {:noreply, map}
    end
  end

  def handle(%Req{action: :max_threads} = req, map) do
    {key, max_t} = req.data

    case map[key] do
      {:pid, worker} ->
        send(worker, {:!, {:max_threads, max_t, req.from}})
        {:noreply, map}

      {nil, oldmax_t} ->
        # If there is no value with such key and the new
        # max_threads == @max_threads (default) — we can remove
        # it safely as there is no need to store it anymore.
        map =
          if max_t == @max_threads do
            Map.delete(map, key)
          else
            put_in(map[key], {nil, max_t})
          end

        {:reply, oldmax_t, map}

      {value, oldmax_t} ->
        map = put_in(map[key], {value, max_t})
        {:reply, oldmax_t, map}

      nil ->
        map = put_in(map[key], {nil, max_t})
        {:reply, @max_threads, map}
    end
  end

  def handle(%Req{action: :fetch, data: key} = req, map) do
    if req[:!] do
      {:reply, fetch(map, key), map}
    else
      fun = fn v ->
        if Process.get(:"$has_value?") do
          {:ok, v}
        else
          :error
        end
      end

      handle(%Req{action: :get, data: {key, fun}})
    end
  end

  def handle(%Req{action: :get, data: {fun, [key]}} = req, map) do
    fun = fn v ->
      Process.put(:"$keys", [key])

      if Process.get(:"$has_value?") do
        Process.put(:"$map", %{key: v})
      else
        Process.put(:"$map", %{})
      end

      # Transaction call should not has "$has_value?" key.
      Process.delete(:"$has_value?")

      Callback.run(fun, [[v]])
    end

    handle(%{req | data: {key, fun}}, map)
  end

  def handle(%Req{data: {_fun, keys}} = req, map) when is_list(keys) do
    {:noreply, Transaction.run(req, map)}
  end

  def handle(%Req{action: :get, !: true} = req, map) do
    {key, fun} = req.data

    Task.start_link(fn ->
      value =
        case fetch(map, key) do
          {:ok, value} ->
            Process.put(:"$has_value?", true)
            value
          :error ->
            Process.put(:"$has_value?", false)
            nil
        end

      Process.put(:"$key", key)
      GenServer.reply(req.from, Callback.run(fun, [value]))
    end)

    {:noreply, map}
  end

  def handle(%Req{action: :get} = req, map) do
    {key, fun} = req.data

    case map[key] do
      {:pid, worker} ->
        send(worker, to_msg(req))

        {:noreply, map}

      # Cannot spawn more Task's.
      {_, 1} ->
        map = spawn_worker(map, key)
        handle(req, map)

      {value, :infinity} ->
        Task.start_link(fn ->
          Process.put(:"$key", key)

          if value do
            Process.put(:"$has_value?", true)
          else
            Process.put(:"$has_value?", false)
          end

          GenServer.reply(req.from, Callback.run(fun, [unbox(value)]))
        end)

        {:noreply, map}

      {value, max_t} when max_t > 1 ->
        server = self()

        Task.start_link(fn ->
          Process.put(:"$key", key)

          if value do
            Process.put(:"$has_value?", true)
          else
            Process.put(:"$has_value?", false)
          end

          GenServer.reply(req.from, Callback.run(fun, [unbox(value)]))
          send(server, {:done_on_server, key})
        end)

        map = put_in(map[key], {value, max_t - 1})

        {:noreply, map}

      # No such key.
      nil ->
        map = put_in(map[key], {nil, @max_threads})
        handle(req, map)
    end
  end

  def handle(%Req{action: :put, !: urgent} = req, map) do
    {key, value} = req.data

    case map[key] do
      {{:value, _}, max_t} ->
        map = put_in(map[key], {{:value, value}, max_t})
        {:noreply, map}

      {:pid, worker} ->
        if urgent do
          send(worker, {:!, {:put, value}})
        else
          send(worker, {:put, value})
        end

        {:noreply, map}

      {nil, max_t} ->
        value = {{:value, value}, max_t}
        map = put_in(map[key], value)
        {:noreply, map}

      nil ->
        map = put_in(map[key], {nil, @max_threads})
        handle(req, map)
    end
  end

  def handle(%Req{action: :pop} = req, map) do
    {key, default} = req.data

    case fetch(map, key) do
      {:ok, _} ->
        req = %{req | action: :get_and_update, data: {key, fn _ -> :pop end}}
        handle(req, map)

      :error ->
        {:reply, default, map}
    end
  end

  # :cast, :update, :get_and_update
  def handle(req, map) do
    {key, _} = req.data

    case map[key] do
      {:pid, worker} ->
        send(worker, to_msg(req))
        {:noreply, map}

      _ ->
        map = spawn_worker(map, key)
        handle(req, map)
    end
  end
end

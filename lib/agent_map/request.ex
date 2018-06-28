defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Helpers, Worker, Transaction, Req}
  import Worker, only: [dict: 1, unbox: 1, queue: 1]

  @max_processes 5

  @enforce_keys [:action]

  # action: :get, :get_and_update, :update, :cast, :keys, …
  # data: {key, fun}, {fun, keys}, …
  # from: nil | GenServer.from
  defstruct [
    :action,
    :data,
    :from,
    safe?: true,
    timeout: 5000,
    !: false
  ]

  defp as_map(%{data: {_key, f}} = req) do
    req
    |> Map.from_struct(req)
    |> Map.delete(:data)
    |> Map.put(:fun, f)
  end

  # defp unbox({{{:value, value}, :blocked}, _max_p}), do: {:ok, value}
  # defp unbox({{:value, value}, _max_p}), do: {:ok, value}
  # defp unbox({{nil, :blocked}, _max_p}), do: :error
  # defp unbox({nil, _max_p}), do: :error
  # defp unbox(nil), do: :error

  def fetch(map, key) do
    case map[key] do
      {:pid, worker} ->
        case dict(worker)[:"$value"] do
          nil ->
            :error

          {:value, value} ->
            {:ok, value}
        end

      state ->
        :ignore
        # unbox(state)
    end
  end

  ##
  ## HELPERS
  ##

  defp has_key?(map, key) do
    match?({:ok, _}, fetch(map, key))
  end

  defp reply_error(reason, req, map) do
    if req.safe? do
      unless req.from, do: Logger.error(reason)
      {:reply, {:error, reason}, map}
    else
      {:stop, reason, {:error, reason}, map}
    end
  end

  ##
  ## HANDLERS
  ##

  def handle(%{action: :inc, data: {key, step}} = req, map) do
    arithm_err = %ArithmeticError{
      message: "cannot increment key #{key} — it has a non numeric value #{v}"
    }

    case map[key] do
      {:pid, worker} ->
        fun = fn
          v when is_number(v) ->
            if req.from do
              {:ok, v + step}
            else
              v + step
            end

          _ ->
            if Process.get(:"$value") do
              raise %KeyError{key: key}
            else
              raise arithm_err
            end
        end

        req = %{req | data: {key, fun}}

        act =
          if req.from do
            :get_and_update
          else
            :cast
          end

        send(worker, as_map(%{req | action: act}))
        {:noreply, map}

      {{:value, v}, _} when not is_number(v) ->
        reply_error(arithm_err, req, map)

      {{:value, v}, p} ->
        map = %{map | key => {{:value, v + step}, p}}
        {:reply, :ok, map}

      {nil, _} ->
        reply_error(%KeyError{key: key}, req, map)
    end
  end

  def handle(%{action: :queue_len, data: {key, opts}}, map) do
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
                  not match?({:!, _}, msg)

                _ ->
                  true
              end
          end)

        _ ->
          0
      end

    {:reply, num, map}
  end

  def handle(%{action: :drop, data: keys} = req, map) do
    map =
      Enum.reduce(keys, map, fn key, map ->
        {:noreply, map} =
          handle(
            %{req | action: :delete, data: key},
            map
          )

        map
      end)

    {:noreply, map}
  end

  def handle(%{action: :keys}, map) do
    keys =
      map
      |> Map.keys()
      |> Enum.filter(&has_key?(map, &1))

    {:reply, keys, map}
  end

  def handle(%{action: :values}, map) do
    fun = fn _ ->
      Map.values(Process.get(:"$map"))
    end

    #    handle(%{req | action: :get, data: {fun, Map.keys(map)}}, map)
  end

  def handle(%{action: :delete, data: key} = req, map) do
    case map[key] do
      {:pid, worker} ->
        :ignore
        #        send(worker, to_msg(req))

        if req.from do
          send(worker, {:reply, req.from, :ok})
        end

        {:noreply, map}

      {{:value, _}, @max_processes} ->
        map = Map.delete(map, key)
        {:reply, :ok, map}

      {{:value, _}, mt} ->
        map = put_in(map[key], {nil, mt})
        {:reply, :ok, map}

      {nil, _} ->
        {:reply, :ok, map}

      nil ->
        {:reply, :ok, map}
    end
  end

  def handle(%{action: :max_processes} = req, map) do
    {key, max_p} = req.data

    case map[key] do
      {:pid, worker} ->
        send(worker, req)
        {:noreply, map}

      {nil, oldmax_p} ->
        # If there is no value with such key and the new
        # max_processes == @max_processes (default) — we can remove
        # it safely as there is no need to store it anymore.
        map =
          if max_p == @max_processes do
            Map.delete(map, key)
          else
            %{map | key => {nil, max_p}}
          end

        {:reply, oldmax_p, map}

      {value, oldmax_p} ->
        map = put_in(map[key], {value, max_p})
        {:reply, oldmax_p, map}

      nil ->
        map = put_in(map[key], {nil, max_p})
        {:reply, @max_processes, map}
    end
  end

  def handle(%{action: :fetch, data: key} = req, map) do
    if req.! do
      {:reply, fetch(map, key), map}
    else
      fun = fn v ->
        if Process.get(:"$has_value?") do
          {:ok, v}
        else
          :error
        end
      end

      handle(%Req{action: :get, data: {key, fun}}, map)
    end
  end

  # Any transaction.
  def handle(%{data: {_fun, keys}} = req, map) when is_list(keys) do
    Transaction.handle(req, map)
  end

  def handle(%{action: :get, !: true} = req, map) do
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

  def handle(%{action: :get} = req, map) do
    {key, fun} = req.data

    case map[key] do
      {:pid, worker} ->
        #        send(worker, to_msg(req))
        {:noreply, map}

      # Cannot spawn more Task's.
      {_, 1} ->
        #        map = spawn_worker(map, key)
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

      {value, max_p} when max_p > 1 ->
        server = self()

        Task.start_link(fn ->
          Process.put(:"$key", key)
          Process.put(:"$value", value)

          #          GenServer.reply(req.from, run(req, [unbox(value)]))
          send(server, %{info: :done, key: key, !: true})
        end)

        map = %{map | key => {value, max_p - 1}}

        {:noreply, map}

      # No such key.
      nil ->
        # Let's pretend it's there.
        map = %{map | key => {nil, @max_processes}}
        handle(req, map)
    end
  end

  def handle(%{action: :put} = req, map) do
    {key, value} = req.data

    case map[key] do
      {{:value, _}, max_p} ->
        map = %{map | key => {{:value, value}, max_p}}
        {:reply, :ok, map}

      {:pid, worker} ->
        #       send(worker, to_msg(req))

        if req.from do
          send(worker, %{req | action: :reply, data: :ok})
        end

        {:noreply, map}

      {nil, max_p} ->
        value = {{:value, value}, max_p}
        map = put_in(map[key], value)
        {:reply, :ok, map}

      nil ->
        map = put_in(map[key], {nil, @max_processes})
        handle(req, map)
    end
  end

  def handle(%{action: :pop} = req, map) do
    {key, default} = req.data

    case fetch(map, key) do
      {:ok, _} ->
        fun = fn _ ->
          #! BUG
          hv? = Process.get(:"$has_value?")
          (hv? && :pop) || {default}
        end

        req = %{req | action: :get_and_update, data: {key, fun}}
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
        #        send(worker, to_msg(req))
        {:noreply, map}

      _ ->
        #        map = spawn_worker(map, key)
        handle(req, map)
    end
  end
end

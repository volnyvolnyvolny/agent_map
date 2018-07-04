defmodule AgentMap.Req do
  @moduledoc false

  require Logger

  alias AgentMap.{Common, Worker, Transaction, Req}
  import Worker, only: [dict: 1, unbox: 1, queue: 1]
  import Common, only: [run: 2]

  @max_processes 5

  @enforce_keys [:action]

  # action: :get, :get_and_update, :update, :cast, :keys, …
  # data: {key, fun}, {fun, keys}, …
  # from: nil | GenServer.from
  defstruct [
    :action,
    :data,
    :from,
    :inserted_at,
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

  def fetch(map, key) do
    case map[key] do
      {:pid, worker} ->
        case dict(worker)[:"$value"] do
          nil ->
            :error

          {:value, value} ->
            {:ok, value}
        end

      {{:value, v}, _max_p} ->
        {:ok, v}

      {nil, _max_p} ->
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
    arithm_err =
      &%ArithmeticError{
        message: "cannot increment key #{key} — it has a non numeric value #{&1}"
      }

    case map[key] do
      {:pid, worker} ->
        fun = fn
          v when is_number(v) ->
            {:ok, v + step}

          v ->
            if Process.get(:"$value") do
              raise %KeyError{key: key}
            else
              raise arithm_err.(v)
            end
        end

        req = %{req | action: :get_and_update, data: {key, fun}}

        send(worker, as_map(req))
        {:noreply, map}

      {{:value, v}, _} when not is_number(v) ->
        reply_error(arithm_err.(v), req, map)

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

                _ ->
                  true
              end
          end)

        _ ->
          0
      end

    {:reply, num, map}
  end

  # cast: true
  def handle(%{action: :drop, data: keys, from: nil} = req, map) do
    map =
      Enum.reduce(keys, map, fn key, map ->
        res =
          handle(
            %{req | action: :delete, data: key},
            map
          )

        case res do
          {:noreply, map} ->
            map

          {:reply, :ok, map} ->
            map
        end
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

    handle(%{req | action: :get, data: {fun, Map.keys(map)}}, map)
  end

  def handle(%{action: :delete, data: key} = req, map) do
    case map[key] do
      {:pid, worker} ->
        d = {key, fn _ -> :drop end}
        req = %{req | action: :get_and_update, data: d}
        send(worker, as_msg(req))

        {:noreply, map}

      {{:value, _}, @max_processes} ->
        map = Map.delete(map, key)
        {:reply, :ok, map}

      {_, p} ->
        map = %{map | key => {nil, p}}
        {:reply, :ok, map}

      nil ->
        {:reply, :ok, map}
    end
  end

  def handle(%{action: :max_processes, data: {key, @max_processes}} = req, map) do
    case map[key] do
      {:pid, worker} ->
        send(worker, %{req | data: @max_processes})
        {:noreply, map}

      {value, {p, old_max}} ->
        map = %{map | key => {value, {p, @max_processes}}}
        {:reply, old_max, map}

      {nil, old_max} ->
        map = Map.delete(map, key)
        {:reply, old_max, map}

      {value, old_max} ->
        map = %{map | key => {value, @max_processes}}
        {:reply, old_max, map}

      nil ->
        {:reply, @max_processes, map}
    end
  end

  def handle(%{action: :max_processes} = req, map) do
    {key, max} = req.data

    case map[key] do
      {:pid, worker} ->
        send(worker, %{req | data: max})
        {:noreply, map}

      {value, {p, old_max}} ->
        map = %{map | key => {value, {p, max}}}
        {:reply, old_max, map}

      {value, old_max} ->
        map = %{map | key => {value, max}}
        {:reply, old_max, map}

      nil ->
        map = %{map | key => {nil, max}}
        {:reply, @max_processes, map}
    end
  end

  def handle(%{action: :fetch, data: key} = req, map) do
    if req.! do
      {:reply, fetch(map, key), map}
    else
      fun = fn v ->
        case Process.get(:"$value") do
          {:value, v} ->
            {:ok, v}

          _ ->
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

    {:noreply, map}
  end

  def handle(%{action: :get} = req, map) do
    {key, fun} = req.data

    case map[key] do
      {:pid, worker} ->
        d = dict(worker)
        p = d[:"$processes"]
        max_p = d[:"$max_processes"]

        if p < max_p do
          Task.start_link(fn ->
            Process.put(:"$key", key)
            Process.put(:"$value", d[:"$value"])

            send(worker, %{info: :get!})

            case run(fun, unbox(d[:"$value"])) do
              {:ok, res} ->
                GenServer.reply(req.from, res)

              {:error, reason} ->
                nil
            end

            send(worker, %{info: :done})
          end)
        else
        end

        send(worker, as_msg(req))
        {:noreply, map}

      # Cannot spawn more Task's.
      {_, {p, max_p}} when p == max_p - 1 ->
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
      {{:value, _}, p} ->
        map = %{map | key => {{:value, value}, p}}
        {:reply, :ok, map}

      {:pid, worker} ->
        req = %{
          req
          | action: :get_and_update,
            data: {key, fn _ -> {:ok, value} end}
        }

        send(worker, as_msg(req))

        {:noreply, map}

      {nil, p} ->
        map = %{map | key => {{:value, value}, p}}
        {:reply, :ok, map}

      nil ->
        map = %{map | key => {{:value, value}, @max_processes}}
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

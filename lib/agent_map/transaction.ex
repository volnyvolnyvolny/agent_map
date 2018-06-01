defmodule AgentMap.Transaction do
  @moduledoc false

  alias AgentMap.{Callback, Req, Worker}

  import Enum, only: [uniq: 1]
  import Map, only: [keys: 1]
  import Worker, only: [dict: 1]

  ##
  ## HELPERS
  ##

  defp collect(keys) do
    _collect(%{}, uniq(keys))
  end

  defp _collect(known, []), do: known

  defp _collect(known, keys) do
    receive do
      msg ->
        {worker, value} =
          case msg do
            {ref, msg} when is_reference(ref) -> msg
            msg -> msg
          end

        key = dict(worker)[:"$key"]
        known = put_in(known[key], value)
        _collect(known, keys -- [key])
    end
  end

  # One-key get-transaction!
  def handle(%{action: :get, data: {fun, [key]}} = req, map) do
    fun = fn v ->
      Process.put(:"$keys", [key])

      hv? = Process.get(:"$has_value?")
      Process.put(:"$map", (hv? && %{key: v}) || %{})

      # Transaction call should not has "$has_value?" key.
      Process.delete(:"$has_value?")

      Callback.run(fun, [[v]])
    end

    Req.handle(%{req | data: {key, fun}}, map)
  end

  def handle(%{action: :get, !: true} = req, map) do
    Task.start_link(fn ->
      {fun, keys} = req.data

      map =
        map
        |> Map.take(keys)
        |> Enum.reduce(%{}, fn k, map ->
          case Req.fetch(map, k) do
            {:ok, v} ->
              %{map | k => v}

            _ ->
              map
          end
        end)

      Process.put(:"$map", map)
      values = for k <- keys, do: map[k]
      result = Callback.run(fun, [values])

      GenServer.reply(req.from, result)
    end)

    {:noreply, map}
  end

  def handle(%{action: :get, !: false} = req, map) do
    Task.start_link(fn ->
      {fun, keys} = req.data

      state =
        for k <- uniq(keys) do
          case map[k] do
            {:pid, worker} ->
              send(worker, %{action: :send, to: self()})
              [k]

            {{:value, value}, _max_t} ->
              [{k, value}]

            _ ->
              []
          end
        end
        |> List.flatten()

      [known, unknown] =
        Enum.split_with(
          state,
          &match?({_k, _v}, &1)
        )

      map =
        unknown
        # MUST RETURN MAP WITHOUT KEYS WITHOUT VALUES!
        |> collect()
        |> Enum.into(known)
        |> Enum.into(%{})

      Process.put(:"$map", map)

      values = for k <- keys, do: map[k]
      result = Callback.run(fun, [values])

      GenServer.reply(req.from, result)
    end)
  end

  # get_and_update, update, case
  def handle(%{action: _, data: {_, keys}} = req, map) do
    state =
      for k <- uniq(keys) do
        case map[k] do
          {:pid, worker} ->
            send(worker, %{action: :send, to: self()})
            [k]

          {{:value, value}, _max_t} ->
            [{k, value}]

          _ ->
            []
        end
      end
      |> List.flatten()

    #    {known, workers} = divide(map, keys)

    # rec_workers =
    #   for k <- keys(known), into: workers do
    #     worker = spawn_link(Worker, :loop, [self(), k, map[k]])
    #     send(worker, %{action: :receive})
    #     {k, worker}
    #   end

    # map =
    #   for k <- keys(known), into: map do
    #     {k, {:pid, rec_workers[k]}}
    #   end

    # server = self()

    # {:ok, tr} =
    #   Task.start_link(fn ->
    #     Process.put(:"$gen_server", server)
    #     process(req, known, rec_workers)
    #   end)

    # for {_, w} <- workers do
    #   send(w, %{req | action: :send_and_receive, to: tr})
    # end

    # {:noreply, map}

    # unless keys == uniq(keys) do
    #   raise """
    #           Expected uniq keys for `update`, `get_and_update` and
    #           `cast` transactions. Got: #{inspect(keys)}. Please
    #           check #{inspect(keys -- uniq(keys))} keys.
    #         """
    #         |> String.replace("\n", " ")
    # end
  end

  ##
  ## WILL RUN IN SEPARATE PROCESS
  ##

  def process(%{action: :cast} = req, known, workers) do
    # {fun, keys} = req.data
    # known = collect(known, keys)
    # values = for k <- keys, do: known[k]

    # case Callback.run(fun, [values]) do
    #   :id ->
    #     for k <- keys, do: send(workers[k], :id)

    #   :drop ->
    #     for k <- keys, do: send(workers[k], :drop)

    #   values when length(values) == length(keys) ->
    #     for {key, value} <- Enum.zip(keys, values) do
    #       send(workers[key], %{action: :put, data: value})
    #     end

    #   err ->
    #     raise """
    #             Transaction callback for `cast` or `update` is malformed!
    #             See docs for hint. Got: #{inspect(err)}."
    #           """
    #           |> String.replace("\n", " ")
    # end
  end

  def process(%{action: :update} = req, known, workers) do
    process(%{req | action: :cast}, known, workers)
    GenServer.reply(req.from, :ok)
  end

  def process(%Req{action: :get_and_update} = req, known, workers) do
    # {fun, keys} = req.data
    # known = collect(known, keys)
    # values = for k <- keys, do: known[k]

    # result =
    #   case Callback.run(fun, [values]) do
    #     :pop ->
    #       for k <- keys, do: send(workers[k], :drop)
    #       {:reply, values}

    #     :id ->
    #       for k <- keys, do: send(workers[k], :id)
    #       {:reply, values}

    #     {get} ->
    #       for k <- keys, do: send(workers[k], :id)
    #       {:reply, get}

    #     {:chain, {fun, new_keys}, values} ->
    #       gen_server = Process.get(:"$gen_server")

    #       for {k, value} <- Enum.zip(keys, values) do
    #         send(workers[k], %{action: :put, data: value})
    #       end

    #       send(gen_server, {:chain, {fun, new_keys}, req.from})
    #       :noreply

    #     {get, :id} ->
    #       for k <- keys, do: send(workers[k], :id)
    #       {:reply, get}

    #     {get, :drop} ->
    #       for k <- keys, do: send(workers[k], :drop)
    #       {:reply, get}

    #     {get, values} when length(values) == length(keys) ->
    #       for {k, value} <- Enum.zip(keys, values) do
    #         send(workers[k], %{action: :put, data: value})
    #       end

    #       {:reply, get}

    #     results when length(results) == length(keys) ->
    #       result =
    #         for {k, oldvalue, result} <- Enum.zip([keys, values, results]) do
    #           case result do
    #             {get, value} ->
    #               send(workers[k], %{action: :put, data: value})
    #               get

    #             :pop ->
    #               send(workers[k], %{action: :drop})
    #               oldvalue

    #             :id ->
    #               send(workers[k], :id)
    #               oldvalue
    #           end
    #         end

    #       {:reply, result}

    #     err ->
    #       raise """
    #             Transaction callback for `get_and_update` is malformed!
    #             See docs for hint. Got: #{inspect(err)}."
    #             """
    #             |> String.replace("\n", " ")
    #   end

    # with {:reply, result} <- result do
    #   GenServer.reply(req.from, result)
    # end
  end
end

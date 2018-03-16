defmodule AgentMap.Transaction do
  @moduledoc false

  alias AgentMap.{Callback, Req, Worker}

  import Enum, only: [uniq: 1]
  import Map, only: [keys: 1]

  ##
  ## HELPERS
  ##

  defp divide(map, keys) do
    Enum.reduce(uniq(keys), {%{}, %{}}, fn key, {known, workers} ->
      case map[key] do
        {:pid, worker} ->
          {known, put_in(workers[key], worker)}

        {{:value, value}, _} ->
          {put_in(known[key], value), workers}

        _ ->
          {put_in(known[key], nil), workers}
      end
    end)
  end

  #

  defp collect(known, keys), do: _collect(known, uniq(keys) -- keys(known))

  defp _collect(known, []), do: known

  defp _collect(known, keys) do
    receive do
      msg ->
        {from, value} =
          case msg do
            {ref, msg} when is_reference(ref) -> msg
            msg -> msg
          end

        {_, dict} = Process.info(from, :dictionary)
        key = dict[:"$key"]
        known = put_in(known[key], value)
        _collect(known, keys -- [key])
    end
  end

  ##
  ## WILL RUN BY SERVER
  ##

  def run(%Req{action: :get, !: true} = req, map) do
    {_, keys} = req.data
    {known, workers} = divide(map, keys)

    known =
      for {key, w} <- workers, into: known do
        {key, Worker.value(w)}
      end

    Task.start_link(__MODULE__, :process, [req, known])
    map
  end

  def run(%Req{action: :get} = req, map) do
    {_, keys} = req.data
    {known, workers} = divide(map, keys)

    {:ok, tr} = Task.start_link(__MODULE__, :process, [req, known])

    for {_key, w} <- workers, do: send(w, {:t_send, tr})
    map
  end

  def run(req, map) do
    {_, keys} = req.data

    unless keys == uniq(keys) do
      raise """
            Expected uniq keys for transactions that changing value
            (`update`, `get_and_update`, `cast`). Got: #{inspect(keys)}.
            Please check #{inspect(keys -- uniq(keys))} keys.
            """
            |> String.replace("\n", " ")
    end

    {known, workers} = divide(map, keys)

    rec_workers =
      for k <- keys(known), into: workers do
        worker = spawn_link(Worker, :loop, [self(), k, map[k]])
        send(worker, :t_get)
        {k, worker}
      end

    map =
      for k <- keys(known), into: map do
        {k, {:pid, rec_workers[k]}}
      end

    {:ok, tr} = Task.start_link(__MODULE__, :process, [req, known, rec_workers])

    if req.! do
      for {_, w} <- workers, do: send(w, {:!, {:t_send_and_get, tr}})
    else
      for {_, w} <- workers, do: send(w, {:t_send_and_get, tr})
    end

    map
  end

  ##
  ## WILL RUN BY SEPARATE PROCESS
  ##

  def process(%Req{action: :get, !: true} = req, known) do
    {fun, keys} = req.data
    values = for key <- keys, do: known[key]
    GenServer.reply(req.from, Callback.run(fun, [values]))
  end

  def process(%Req{action: :get} = req, known) do
    {_, keys} = req.data
    process(%{req | :! => true}, collect(known, keys))
  end

  def process(%Req{action: :cast} = req, known, workers) do
    {fun, keys} = req.data
    known = collect(known, keys)
    values = for k <- keys, do: known[k]

    case Callback.run(fun, [values]) do
      :id ->
        for k <- keys, do: send(workers[k], :id)

      :drop ->
        for k <- keys, do: send(workers[k], :drop)

      values when length(values) == length(keys) ->
        for {key, value} <- Enum.zip(keys, values) do
          send(workers[key], {:put, value})
        end

      err ->
        raise """
              Transaction callback for `cast` or `update` is malformed!
              See docs for hint. Got: #{inspect(err)}."
              """
              |> String.replace("\n", " ")
    end
  end

  def process(%Req{action: :update} = req, known, workers) do
    process(%{req | :action => :cast}, known, workers)
    GenServer.reply(req.from, :ok)
  end

  def process(%Req{action: :get_and_update} = req, known, workers) do
    {fun, keys} = req.data
    known = collect(known, keys)
    values = for k <- keys, do: known[k]

    result =
      case Callback.run(fun, [values]) do
        :pop ->
          for k <- keys, do: send(workers[k], :drop)
          values

        :id ->
          for k <- keys, do: send(workers[k], :id)
          values

        {get} ->
          for k <- keys, do: send(workers[k], :id)
          get

        {get, :id} ->
          for k <- keys, do: send(workers[k], :id)
          get

        {get, :drop} ->
          for k <- keys, do: send(workers[k], :drop)
          get

        {get, values} when length(values) == length(keys) ->
          for {key, value} <- Enum.zip(keys, values) do
            send(workers[key], {:put, value})
          end

          get

        results when length(results) == length(keys) ->
          for {key, oldvalue, result} <- Enum.zip([keys, values, results]) do
            case result do
              {get, value} ->
                send(workers[key], {:put, value})
                get

              :pop ->
                send(workers[key], :drop)
                oldvalue

              :id ->
                send(workers[key], :id)
                oldvalue
            end
          end

        err ->
          raise """
                Transaction callback for `get_and_update` is malformed!
                See docs for hint. Got: #{inspect(err)}."
                """
                |> String.replace("\n", " ")
      end

    GenServer.reply(req.from, result)
  end
end

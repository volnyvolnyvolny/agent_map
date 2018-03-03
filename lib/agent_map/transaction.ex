defmodule AgentMap.Transaction do
  @moduledoc false

  alias AgentMap.{Callback, Req, Worker}


  import Enum, only: [uniq: 1]
  import Map, only: [keys: 1]


  def divide(map, keys) do
    Enum.reduce uniq(keys), {%{}, %{}}, fn key, {known, workers} ->
      case map[key] do
        {:pid, worker} ->
          {known, put_in(workers[key], worker)}

        {{:state, state}, _} ->
          {put_in(known[key], state), workers}

        _ ->
          {put_in(known[key], nil), workers}
      end
    end
  end


  defp collect(known, keys), do: _collect( known, (uniq keys)--keys known)

  defp _collect(known, []), do: known
  defp _collect(known, keys) do
    receive do
      msg ->
        {from, state} = case msg do
          {ref, msg} when is_reference(ref) -> msg
          msg -> msg
        end

        {_, dict} = Process.info from, :dictionary
        key = dict[:'$key']
        known = put_in known[key], state
       _collect known, keys--[key]
    end
  end


  ##
  ## WILL RUN BY SERVER
  ##

  def run(%Req{action: :get, !: true}=req, map) do
    {_, keys} = req.data
    {known, workers} = divide map, keys

    known = for {key, w} <- workers, into: known do
      {_, dict} = Process.info w, :dictionary
      {key, dict[:'$state']}
    end

    Task.start_link __MODULE__, :process, [req, known]
    map
  end

  def run(%Req{action: :get}=req, map) do
    {_,keys} = req.data
    {known, workers} = divide map, keys

    {:ok, tr} =
      Task.start_link __MODULE__, :process, [req, known]

    for {_key, w} <- workers, do: send w, {:t_send, tr}
    map
  end

  # One-key transaction
  def run(%Req{data: {fun, [key]}}=req, map) do
    case map[key] do
      {:pid, worker} ->
        req = %{req | action: {:one_key_t, req.action},
                      data: {key, &Callback.run(fun, [[&1]])}}
        send worker, Req.to_msg req
        map

      _ ->
        map = Req.spawn_worker map, key
        run req, map
    end
  end

  def run(req, map) do
    {_, keys} = req.data

    unless keys == uniq keys do
      raise """
            Expected uniq keys for transactions that changing state
            (`update`, `get_and_update`, `cast`). Got: #{inspect keys}.
            Please check #{inspect(keys--uniq keys)} keys.
            """
            |> String.replace("\n", " ")
    end

    {known, workers} = divide map, keys

    rec_workers = for k <- keys(known), into: workers do
      worker = spawn_link Worker, :loop, [self(), k, map[k]]
      send worker, :t_get
      {k, worker}
    end

    map = for k <- keys(known), into: map do
      {k, {:pid, rec_workers[k]}}
    end

    {:ok, tr} =
      Task.start_link __MODULE__, :process, [req, known, rec_workers]

    if req.! do
      for {_, w} <- workers, do: send( w, {:!, {:t_send_and_get, tr}})
    else
      for {_, w} <- workers, do: send( w, {:t_send_and_get, tr})
    end
    map
  end


  ##
  ## WILL RUN BY SEPARATE PROCESS
  ##

  def process(%Req{action: :get, !: true}=req, known) do
    {fun, keys} = req.data
    states = for key <- keys, do: known[key]
    GenServer.reply req.from, Callback.run(fun, [states])
  end

  def process(%Req{action: :get}=req, known) do
    {_, keys} = req.data
    process %{req | :! => true}, collect(known, keys)
  end

  def process(%Req{action: :cast}=req, known, workers) do
    {fun, keys} = req.data
    known = collect known, keys
    states = for key <- keys, do: known[key]

    case Callback.run fun, [states] do
      c when c in [:id, :drop] ->
        for key <- keys do
          send workers[key], c
        end

      results when length(results) == length(keys) ->
        for {key, state} <- Enum.zip keys, results do
          send workers[key], {:put, state}
        end

      err ->
        raise """
              Transaction callback for `cast` or `update` is malformed!
              See docs for hint. Got: #{inspect err}."
              """
              |> String.replace("\n", " ")
    end
  end

  def process(%Req{action: :update}=req, known, workers) do
    process %{req | :action => :cast}, known, workers
    GenServer.reply req.from, :ok
  end

  def process(%Req{action: :get_and_update}=req, known, workers) do
    {fun, keys} = req.data
    known = collect known, keys
    states = for key <- keys, do: known[key]

    case Callback.run fun, [states] do
      :pop ->
        for key <- keys do
          send workers[key], :drop
        end
        states

      {get, res} when res in [:drop, :id] ->
        for key <- keys do
          send workers[key], res
        end
        get

      {get, states} when length(states) == length(keys) ->
        for {key, state} <- Enum.zip keys, states do
          send workers[key], {:put, state}
        end
        get

      results when length(results) == length(keys) ->
        for {key, oldstate, result} <- Enum.zip [keys, states, results] do
          case result do
            {get, state} ->
              send workers[key], {:put, state}
              get
            :pop ->
              send workers[key], :drop
              oldstate
            :id ->
              send workers[key], :id
              oldstate
          end
        end

      err -> raise """
                   Transaction callback for `get_and_update` is malformed!
                   See docs for hint. Got: #{inspect err}."
                   """
                   |> String.replace("\n", " ")
    end
    |> (&GenServer.reply req.from, &1).()
  end

end

defmodule MultiAgent.Transaction do
  @moduledoc false

  alias MultiAgent.Callback


  import Enum, only: [uniq: 1]
  import Map, only: [keys: 1]
  import Callback, only: [parse: 1]


  def divide( map, keys) do
    Enum.reduce uniq(keys), {%{}, %{}}, fn key, {known, workers} ->
      case map do
        %{^key => {state,_,_}} ->
          {known |> Map.put(key, parse state), workers}
        %{^key => {:pid, worker}} ->
          {known, workers |> Map.put(key, worker)}
        _ ->
          {known |> Map.put(key, nil), workers}
      end
    end
  end


  defp collect( known, keys), do: _collect( known, (uniq keys)--keys known)

  defp _collect( known, []), do: known
  defp _collect( known, keys) do
    receive do
      msg ->
        {from, state} = case msg do
          {_ref, msg} -> msg
          msg         -> msg
        end

        {:dictionary, dict} =
          Process.info( from, :dictionary)
        key = dict[:'$key']
        known = Map.put known, key, state
       _collect( known, keys--[key])
    end
  end


  defp rec do
    receive do
      msg -> msg
    end
  end


  def run({:!, {:get, {_,keys},_}}=msg, map) do
    {known, workers} = divide map, uniq keys

    known =
      for {key, worker} <- workers, into: known do
        {:dictionary, dict} =
           Process.info worker, :dictionary

        {key, dict[:'$state']}
      end

    Task.start_link fn ->
      process msg, known
    end
    map
  end

  def run({:get, {_,keys}, _}=msg, map) do
    {known, workers} = divide map, keys

    tr = Task.start_link fn ->
      process msg, known
    end

    for {_key, worker} <- workers do
      send worker, {:get, & &1, tr, :infinity}
    end
    map
  end


  def run({:!, msg}=msg, map) do
    run msg, map, :!
  end

  def run( msg, map) do
    run msg, map, nil
  end

  def run( msg, map, urgent) do
    {_, keys} = elem msg, 1

    unless keys == uniq keys do
      raise """
            Expected uniq keys for changing transactions (update,
            get_and_update, cast).
            """
            |> String.replace("\n", " ")
    end

    {known, workers} = divide map, keys

    rec_workers =
      for key <- keys( known), into: workers do
        worker = spawn_link Worker, :loop, [self(), key, map[key]]
        send worker, {:t, fn _ -> rec() end}
        {key, worker}
      end

    tr = Task.start_link fn ->
      process msg, known, rec_workers
    end

    send_rec = fn state ->
      send tr, {self(), state}
      rec()
    end

    for w <- workers, !urgent, do: send w, {:t, send_rec}
    for w <- workers,  urgent, do: send w, {:!, {:t, send_rec}}
    map
  end


  def process({:!, {:get, {fun,keys}, from}}, known) do
    states = for key <- keys, do: known[key]
    GenServer.reply from, Callback.run( fun, [states])
  end

  def process({:get, {_,keys}, _}=msg, known) do
    process {:!, msg}, collect( known, keys)
  end

  def process({:cast, {fun,keys}}, known, workers) do
    known = collect known, keys
    states = for key <- keys, do: known[key]

    case Callback.run fun, [states] do
      :pop ->
        for worker <- workers do
          send worker, :drop_state
        end

      results when length( results) == length( keys) ->
        for {key, state} <- Enum.zip keys, results do
          send workers[key], {:new_state, state}
        end

      _ ->
        raise """
              Transaction callback is malformed!
              Expected to be returned :pop or a list with a
              new state for every key involved. See docs for hint."
              """
              |> String.replace("\n", " ")
    end
  end

  # drop urgent sign
  def process({:update, {fun,keys}, from}, known, workers) do
    process {:cast, {fun,keys}}, known, workers
    GenServer.reply from, :ok
  end

  def process({:get_and_update, {fun,keys}, from}, known, workers) do
    known = collect known, keys
    states = for key <- keys, do: known[key]

    case Callback.run fun, [states] do
      :pop ->
        for {_,worker} <- workers, do: send worker, :drop_state
        states

      {get, states} when length( states) == length( keys) ->
        for {key, state} <- Enum.zip keys, states do
          send workers[key], {:new_state, state}
        end
        get

      results when length( results) == length( keys) ->
        for {key, state, result} <- Enum.zip [keys, states, results] do
          case result do
            {get, state} ->
              send workers[key], {:new_state, state}
              get
            :pop ->
              send workers[key], :drop_state
              state
            :id ->
              send workers[key], :id
              state
          end
        end

      _ -> raise """
                 Transaction callback is malformed!
                 Expected to be returned :pop, a list with a
                 new state for every key involved or a pair
                 {returned value, new states}. See docs."
                 """
                 |> String.replace("\n", " ")
    end
    |> (&GenServer.reply from, &1).()
  end

end

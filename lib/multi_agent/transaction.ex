defmodule MultiAgent.Transaction do
  @moduledoc false

  import Enum, only: [uniq: 1]
  import Map, only: [take: 2, keys: 1, put: 3]
  import Callback, only: [parse: 1]


  def divide( map, keys) do
    keys = uniq keys
    Enum.reduce keys, {%{}, %{}}, fn key, {known, workers} ->
      case map[key] do
        nil -> {put( known, key, nil), workers}
        {state,_,_} -> {put( known, key, parse state), workers}
        {:pid, worker} -> {known, put( workers, key, worker)}
      end
    end
  end

  defp collect( known, keys), do: _collect( known, (uniq keys)--keys known)

  defp _collect( known, []), do: known
  defp _collect( known, keys) do
    receive do
      msg ->
        msg = case msg do
                {_ref, msg} -> msg
                msg         -> msg
              end

        {from, state} = msg

        {:dictionary, dict} =
          Process.info( from, :dictionary)
        key = dict[:'$key']
        known = put known, key, state
       _collect( known, keys--[key])
    end
  end


  defp rec do
    receive do
      msg -> msg
    end
  end

  defp send_rec( t, state) do
    send t, {self, state}
    rec
  end



  def run({{:get,:!}, {fun,keys}, from}=msg, map) do
    {known, workers} = divide map, uniq( keys)

    known =
      for {key, worker} <- workers, into: known do
        {:dictionary, dict} =
          Process.info( worker, :dictionary)
        {key, dict[:'$state']}
      end

    Task.start_link fn -> process msg, known end
    map
  end


  def run({:get, {fun,keys}, from}=msg, map) do
    {known, workers} = divide map, keys

    t = Task.start_link fn -> process msg, known end

    for {_key, worker} <- workers do
      send worker, {:get, & &1, t, :infinity}
    end
    map
  end


  def run({{action,:!}, data, from}=msg, map) do
    run msg, map, :!
  end

  def run({action,_,_}=msg, map) do
    run msg, map, nil
  end


  def run({_, {_,keys},_from}=msg, map, urgent) do
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
        worker = spawn_link Worker, :loop, [self, key, map[key]]
        send worker, {:t, fn _ -> rec end}
        {key, worker}
      end

    t = Task.start_link fn ->
      process msg, known, rec_workers
    end

    for worker <- workers do
      if urgent do
        send worker, {:!, {:t, &send_rec( t, &1)}}
      else
        send worker, {:t, &send_rec( t, &1)}
      end
    end
  end


  def process({{:get,:!}, {fun,keys}, from}, known) do
    states = Enum.map keys, &known[&1]
    GenServer.reply from, Callback.run( fun, [states])
  end

  def process({:get, {fun,keys}, from}, known) do
    known = collect known, keys
    process {{:get,:!}, {fun,keys}, from}, known
  end

  def process({a, {fun,keys}}, known, workers) when a in [:cast, {:cast,:!}] do
    known = collect known, keys
    states = for key <- keys, do: known[key]

    case Callback.run fun, [states] do
      :pop ->
        for worker <- workers do
          send worker, :drop_state
        end

      results when length results == length keys ->
        for {key, state} <- Enum.zip keys, results do
          send workers[key], {:new_state, state}
        end

      _ -> raise """
                 Transaction callback is malformed!
                 Expected to be returned :pop or a list with a
                 new state for every key involved. See docs."
                 """
                 |> String.replace("\n", " ")
    end
  end

  # drop urgent sign
  def process({{act,:!}, data, from}, known, workers) do
    process({act, data, from}, known, workers)
  end

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

      {get, states} when length states = length keys ->
        for {key, state} <- Enum.zip keys, results do
          send workers[key], {:new_state, state}
        end
        get

      results when length results == length keys ->
        for {key, state, result} <- Enum.zip [keys, states, results] do
          case result do
            {get, state} ->
              send worker[key], {:new_state, state}
              get
            :pop ->
              send worker[key], :drop_state
              state
            :id ->
              send worker[key], :id
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
    |> GenServer.reply( from, &1).()
  end

end

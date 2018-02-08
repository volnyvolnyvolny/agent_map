defmodule MultiAgent.Transaction do
  @moduledoc false

  alias MultiAgent.{Callback, Req}


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


  #
  # on server
  #

  def run(%Req{action: :get, !: true}=req, map) do
    {known, workers} = divide map, keys

    known = for {key, w} <- workers, into: known do
              {:dictionary, dict}
                = Process.info w, :dictionary
              {key, dict[:'$state']}
            end

    Task.start_link fn ->
      process req, known
    end
    map
  end

  def run(%Req{action: :get}=req, map) do
    {known, workers} = divide map, keys

    tr = Task.start_link fn ->
      process req, known
    end

    for {_, worker} <- workers do
      send worker, {:t_send, tr}
    end
    map
  end

  def run( req, map) do
    {_, keys} = req.data

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
        send worker, :t_get
        {key, worker}
      end

    tr = Task.start_link fn ->
      process req, known, rec_workers
    end

    for w <- workers do
      if req.urgent do
        send w, {:!, {:t_send_and_get, tr}}
      else
        send w, {:t_send_and_get, tr}
      end
    end
    map
  end


  #
  # on separate process
  #

  def process(%Req{action: :get, !: true}=req, known) do
    {fun, keys} = req.data
    states = for key <- keys, do: known[key]
    GenServer.reply from, Callback.run( fun, [states])
  end

  def process(%Req{action: :get}=req, known) do
    {_, keys} = req.data
    process %{req | :! => true}, collect( known, keys)
  end

  def process(%Req{action: :cast}=req, known, workers) do
    {fun, keys} = req.data
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
        for {_,worker} <- workers,
          do: send( worker, :drop_state)
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
    |> (&GenServer.reply req.from, &1).()
  end

end

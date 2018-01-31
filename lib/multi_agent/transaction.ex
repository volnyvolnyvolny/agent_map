defmodule MultiAgent.Transaction do
  @moduledoc false

  @compile {:inline, state: 2}

  # schema:
  # prepair → ask → collect → answer


  # divide values to known and holded by workers
  defp separate( map, keys) do
    keys = Enum.uniq( keys)
    map = Map.take( map, keys)

    {workers, known}
      = Enum.split_with( map, fn {_,state} ->
          match?({:pid,_}, state)
        end)

    known = Enum.map( known, fn {key, {state,_,_}} ->
              {key, parse( state)}
            end)

    # nil's for unknown keys
    known = Enum.into( keys--Map.keys( map), known, & {&1,nil})
    workers = Enum.map workers, fn {:pid, pid} -> pid end

    {known, workers}
  end


  defp reply( map, keys, :pop) do
    keys = Enum.uniq keys
    reply_workers( map, keys, List.duplicate(:drop_state, length keys))
  end

  defp reply( map, keys, replies) do
    replies = Enum.zip( keys, replies)
              |> Enum.uniq_by( fn {k,_} -> k end)

    for {key, reply} <- replies do
      {worker,_} = map[key]
      send worker, reply
    end
  end


  defp answer(:get_and_update, map, keys, {get, replies}) do
    reply( map, keys, replies)
    get
  end

  defp answer(:get_and_update, map, keys, :pop) do
    answer(:get_and_update, map, keys, List.duplicate(:pop, length keys))
  end

  defp answer(:get_and_update, map, keys, results) do
    results = Enum.zip keys, results
    {get, replies} = for {key,result} <- results do
                       case result do
                         :pop -> {map[key], :drop}
                         :id -> {map[key], :id}
                         {get,state} -> {get, {:state, state}}
                       end
                     end
                     |> List.unzip()

    reply( map, keys, replies)
    get
  end

  defp answer(:update, map, keys, results) do
    replies = Enum.map results, & {:new_state, &1}
    reply( map, keys, replies)
    :ok
  end


  defp state( known, key) do
    case known[key] do
      {state} -> state
      {_from, state} -> state
    end
  end


  defp prepair({{:get, :!}, fun, keys, from}, map) do
    {known, workers} = separate( map, keys)

    # took state from workers dictionaries
    known = Enum.into( workers, known, fn worker ->
              {Process.info( worker, :dictionary)[:'$key'],
               Process.info( worker, :dictionary)[:'$state']}
            end)

    {{known, %{}}, map}
  end

  defp prepair({action, fun, keys, from}, map) do
    {known, workers} = separate( map, keys)

    for <-
  end

  defp prepair({:get, fun, keys, from}, map) do
    {known, workers} = separate( map, keys)


    # took state from workers dictionaries
    known = Enum.into( workers, known, fn worker ->
              {Process.info( worker, :dictionary)[:'$key'],
               Process.info( worker, :dictionary)[:'$state']}
            end)

    {{known, %{}}, map}
  end


  defp prepair( {action, fun, keys, from}, map) do
    {known, workers} = separate( map, keys)

  end

  defp prepair( {action, fun, keys, from}, map) do
    {known, workers} = separate( map, keys)
  end


  defp callback( transaction, state) do
    send transaction, {self(), state}
    receive do
      {:state, state} -> {nil, state}
       :id -> {nil, state}
       :drop -> :pop
    end
  end


  defp ask({:get, :!},_workers,_transaction), do: ignore
  defp ask(:get, workers, transaction) do
    for worker <- workers do
      send worker, {:get, & &1, trans_pid, :infinity}
    end
  end

  defp ask({action, :!}, workers, trans) do
    for worker <- workers do
      send worker, {:!, {action, &callback( trans, &1), trans, :infinity}}
    end
  end

  defp ask( action, workers, trans) do
    for worker <- workers do
      send worker, {action, &callback( trans, &1), trans, :infinity}
    end
  end


  defp collect( known, keys) do
    loop = fn from, state ->
             case keys--Map.keys( known) do
               [] -> known
               _ ->
                 key = Process.info( from, :dictionary)[:'$key']
                 known = Map.put( known, key, {from, state})
                 collect( known, keys)
             end
           end

    receive do
      {_ref, {from, state}} -> loop.( from, state)
      {from, state} -> loop.( from, state)
    end
  end


  defp action( {action,_fun,_keys,_from}), do: action
  defp action( {action,_fun,_keys}), do: action

  def run( msg, map) do
    {{known, workers}, map} = prepair( msg, map)
    t = Task.start_link( Transaction, :flow, [known, msg, from])
    ask( action( msg), workers, t)
  end

  # transaction loop (:get, :get!, :get_and_update, :update, :cast)
  defp flow( known, {action, fun, keys}, from) do
    known = collect( known, Enum.uniq keys)
    states = Enum.map( keys, &state( known, &1))
    results = Callback.run( fun, [states])

    case action do
      :get ->
        GenServer.reply( from, results)
      act when act in [:get_and_update, :update] ->
        GenServer.reply( from, answer( act, map, keys, results))
      :cast ->
        answer(:update, map, keys, results)
    end
  end
end

defmodule MultiAgent.Transaction do
  @moduledoc false

  @compile {:inline, state: 2}

  defp state( map, key) do
    case map[key] do
      {state} -> state
      {_,state} -> state
    end
  end


  defp collect( known, keys) do
    receive do
      {from, state} ->
        case keys--Map.keys( known) do
          [] -> known
          _ ->
            key = Process.info( from, :dictionary)[:'$key']
            collect( Map.put_new( known, key, {from, state}), keys)
        end
    end
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
                         :pop -> {map[key], :drop_state}
                         :id -> {map[key], :id}
                         {get,state} -> {get,{:new_state, state}}
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


  defp separate( map, keys) do
    map = Map.take( map, keys)

    {workers, known}
      = Enum.split_with( map, fn {_,state} ->
          match?({:pid,_}, state)
        end)

    known = Enum.map( known, fn {k, {state,_,_}} ->
              {k, {parse( state)}}
            end)

    # nil's for unknown keys
    known = Enum.into( keys--Map.keys( map), known, & {&1,{nil}})
    workers = Enum.map workers, fn {:pid, pid} -> pid end

    {known, workers}
  end


  defp prepair( {{:get, :!}, fun, keys}, from, map) do
    {known, workers} = separate( map, keys)

    get_state = &Process.info(&1, :dictionary)[:'$state']
    known = Enum.into( workers, known, get_state)
    {known, map}
  end

  defp prepair( {:get, fun, keys}, from, map) do
  end


  defp prepair( {action, fun, keys}, from, map) do
    {known, workers} = separate( map, keys)

  end

  defp prepair( {action, fun, keys}, from, map) do
    {known, workers} = separate( map, keys)
  end

  def run( msg, map) do
    {known, map} = Transaction.prepair( msg, from, map)

    msg = case action do
            {action, :!} -> {action, fun, keys}
            _ -> msg
          end

    Task.start_link( Transaction, :flow, [known, msg, from])

    {:noreply, map}
  end

  # transaction loop (:get, :get!, :get_and_update, :update, :cast)
  defp flow( known, {action, fun, keys}, from) do
    map = collect( known, Enum.uniq keys)
    states = Enum.map( keys, &state( map, &1))

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

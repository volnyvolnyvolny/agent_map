defmodule MultiAgent.Transaction do
  @moduledoc false

  @compile {:inline, state: 2}


  import Enum, only: [uniq: 1]


  # server:      prepair → ask → noreply
  # transaction:               → collect → answer → reply


  # divide values to known and holded by workers
  defp divide( map, keys) do
    keys = uniq keys
    map = Map.take( map, keys)

    # nil's for unknown keys
    known = keys--Map.keys( map)
            |> Enum.into(%{}, & {&1,nil})

    Enum.reduce( map, {known,%{}}, fn {key, state}, {ks,ws} ->
      case state do
        {:pid, pid} ->
          {ks, Map.put( ws, key, pid)}
        {state,_,_} ->
          {Map.put( ks, key, parse( state)), ws}
      end
    end
  end

  defp prepair({{:get, :!}, fun, keys, from}, map) do
    {known, workers} = divide( map, keys)

    # took states from workers dicts
    known = Enum.into( workers, known, fn worker ->
              dict = Process.info( worker, :dictionary)
              {dict[:'$key'], {:server, dict[:'$state']}}
            end)

    {{known, %{}}, map} # know everything
  end

  defp prepair({:get, fun, keys, from}, map) do
    {divide( map, keys), map}
  end

  defp prepair({action, fun, keys, from}, map) do
    {known, workers} = separate( map, keys)

    workers
      = Enum.into( known, workers, fn {key,tuple} ->
          {key, spawn_link( Worker, :loop, [self(), key, tuple])}
        end)

    {{known, workers}, map}
  end


  def callback( :get,_tr, state), do: state
  def callback( act, tr, state) when act in [:get_and_update,
                                             :get_and_update!] do
    send tr, {self(), state}
    receive do
      {:state, state} -> {nil, state}
      :id -> {nil, state}
      :drop -> :pop
    end
  end

  def callback( act, tr, state) when act in [:update, :update!] do
    send tr, {self(), state}
    receive do
      {:state, state} -> state
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


  defp state( known, key) do
    case known[key] do
      {:server, state} -> state
      {_from, state} -> state
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

  defp action( {action,_fun,_keys,_from}), do: action
  defp action( {action,_fun,_keys}), do: action

  def run( msg, map) do

    fire( action( msg, known, workers))
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

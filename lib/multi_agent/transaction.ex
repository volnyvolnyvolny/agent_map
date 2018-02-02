defmodule MultiAgent.Transaction do
  @moduledoc false

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
    end)
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



  defp collect( known, []), do: known
  defp collect( known, keys) do
    receive do
      msg ->
        {from, state} = case msg do
                          {_ref, msg} -> msg
                          msg -> msg
                        end
        key = Process.info( from, :dictionary)[:'$key']
        known = Map.put( known, key, {from, state})
        collect( known, keys--[key])
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

  defp reply(:cast, {fun,keys}, workers, results) do
    replies = Enum.map results, & {:new_state, &1}
    reply( map, keys, replies)
    :ok
  end


  defp body( keys, fun, known) do
    known = collect( known, Enum.uniq keys)
    states = Enum.map( keys, &known[&1])
    Callback.run fun, [states]
  end


  defp interpret(:get_and_update, states, :pop), do: states
  defp interpret(:get_and_update,_states, {get,_}), do: get
  defp interpret(:get_and_update, states, results) when is_list( results) do
    unless length states == length results, do:
      raise "get_and_update callback is malformed! " <>
            "States and results lengths are not equal. See docs."

    Enum.unzip( results) |> elem(0)
  end


  defp reply(:get, from, results), do: GenServer.reply from, results
  defp reply(:get_and_update, from, {get,_}), do: GenServer.reply get
  defp reply(:get_and_update, from, :pop) do
    GenServer.OB
  end
  defp reply(:update, from,_results), do: GenServer.reply from, :ok



  def flow({:cast, {fun,keys}}, {known,workers}) do
    {states,results} = body keys, fun, known
    unless length states == length results do
      raise "get_and_update callback is malformed! " <>
            "States and results lengths are not equal. See docs."
    end

    case  do
      :drop -> 
        for {worker,state}  <- Enum.zip( workers, results) do
          send worker, {:new_state, state}
        end
    end
    for {worker,state}  <- Enum.zip( workers, results) do
      send worker, {:new_state, state}
    end
  end

  def flow({:update, fks, from}, info) do
    flow {:cast, fks}, info
    GenServer.reply from, :ok
  end

  def flow({:get, {_fun,keys}, from}, {known,_workers}) do
    {_,results} = body keys, fun, known
    GenServer.reply from, result
  end

  def flow({:get_and_update, fks, from}, info) do
    {states,results} = body( keys, fun, known)
    case results do
      {get,_} -> get
      :pop -> state
    end
  end

end

defmodule MultiAgent.Transaction do
  @moduledoc false

  import Enum, only: [uniq: 1]


  # server:      prepair → ask → noreply
  # transaction:               → collect → answer → reply


  # divide values to known and holded by workers
  def divide( map, keys) do
    keys = uniq keys
    map = Map.take( map, keys)

    workers = for {:pid, worker} <- map, do: worker
    known = for {key, {state,_,_}} <- map, into: %{}, do: {key, parse state}
    nils = for key <- keys--Map.keys( map), into: %{}, do: {key, nil}

    {Map.merge( known, nils), workers}
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


  def run({{:get,:!}, {fun,keys}, from}, map) do
    {known, workers} = divide map, keys

    # took states from workers dicts
    known = Enum.into( workers, known, fn worker ->
      dict = Process.info( worker, :dictionary)
      {dict[:'$key'], {:server, dict[:'$state']}}
    end)

    Task.start_link fn ->
      states = Enum.map keys, &known[&1]
      GenServer.reply from, Callback.run fun, [states]
    end
    map
  end


  def run({:get, {fun,keys}, from}=msg, map) do
    {known, workers} = divide map, keys

    t = Task.start_link fn ->
      known = collect known, Enum.uniq keys
      states = Enum.map keys, &known[&1]
      GenServer.reply from, Callback.run fun, [states]
    end

    for worker <- workers do
      dict = Process.info worker, :dictionary
      send worker, {:get, {dict[:'$key'], & &1}, t, :infinity}
    end
    map
  end


  def run({{action,:!}, data, from}=msg, map) do
    run msg, map, {action, :!}
  end

  def run({action,_,_}=msg, map) do
    run msg, map, {action, nil}
  end

  def run({_, {fun,keys}, from}, map, {act,urgent}) when act in [:update, :cast] do
    unless keys == Enum.uniq keys do
      raise """
            Expected uniq keys for changing transactions (update,
            get_and_update or cast).
            """
            |> String.replace("\n", " ")
    end

    {known, workers} = divide map, keys

    t = Task.start_link fn ->
      known = collect known, Enum.uniq keys
      states = Enum.map keys, &known[&1]
      case Callback.run fun, [states] do
        :pop ->
          for worker <- workers, do: send worker, :die

        results when length results == length keys ->
          Enum.zip keys, results |>
          Enum.uniq_by( fn {key,_} -> end)

        _ -> raise """
                   Transaction callback (#{act}) is malformed!
                   Expected to be returned :pop or results list with
                   length equal to the length of states. See docs."
                   """
                   |> String.replace("\n", " ")
      end

      if act == :update, do: GenServer.reply( from, :ok)
    end


    for worker <- workers do
      callback = fn state ->
        send t, {self, state}
        receive do
          new_state -> new_state
        end
      end

      send worker, {:cast, & &1, t, :infinity}
    end


    for {key,state} <- known do
      callback = fn _ ->
        receive do
          new_state -> new_state
        end
      end

      worker = spawn_link( Worker, :loop, [self, key, map[key]])
      if urgent do
        send worker, {:!, {:cast, {key, callback}}}
      else
        send worker, {:cast, {key, callback}}
      end
      {key, {:pid, worker}}
    end
    |> Enum.into( map)
  end


  def run({_, {fun,keys}, from}, map, {:get_and_update,urgent}) do
    unless keys == Enum.uniq keys do
      raise """
            Expected uniq keys for changing transactions (update,
            get_and_update or cast).
            """
            |> String.replace("\n", " ")
    end

    {known, workers} = divide map, keys

    t = Task.start_link fn ->
      known = collect known, Enum.uniq keys
      states = Enum.map keys, &known[&1]
      case Callback.run fun, [states] do
        :pop ->
          for worker <- workers, do: send worker, :die

        results when length results == length keys ->
          Enum.zip keys, results |>
          Enum.uniq_by( fn {key,_} -> end)

        _ -> raise """
                   Transaction callback (#{act}) is malformed!
                   Expected to be returned :pop or results list with
                   length equal to the length of states. See docs."
                   """
                   |> String.replace("\n", " ")
      end



      if act == :update, do: GenServer.reply( from, :ok)
    end


    for worker <- workers do
      callback = fn state ->
        send t, {self, state}
        receive do
          new_state -> new_state
        end
      end

      send worker, {:cast, & &1, t, :infinity}
    end


    for {key,state} <- known do
      callback = fn _ ->
        receive do
          new_state -> new_state
        end
      end

      worker = spawn_link( Worker, :loop, [self, key, map[key]])
      if urgent do
        send worker, {:!, {:cast, {key, callback}}}
      else
        send worker, {:cast, {key, callback}}
      end
      {key, {:pid, worker}}
    end
    |> Enum.into( map)
  end

  def run({{:get,:!}, {fun,keys}, from}, known, workers) do
  end

  def flow({:cast, {fun,keys}}, known, workers) do
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

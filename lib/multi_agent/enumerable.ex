defimpl Enumerable, for: MultiAgent do

  defp pid(%MultiAgent{pid: mag}), do: mag

  def count( mag) do
    {:ok, GenServer.call( pid( mag), :count)}
  end

  def member?( mag, elem) do
    {:ok, GenServer.call( pid( mag), elem)}
  end


  # def reduce(_,       {:halt, acc}, _fun),   do: {:halted, acc}
  # def reduce(list,    {:suspend, acc}, fun), do: {:suspended, acc, &reduce(list, &1, fun)}
  # def reduce([],      {:cont, acc}, _fun),   do: {:done, acc}
  # def reduce([h | t], {:cont, acc}, fun),    do: reduce(t, fun.(h, acc), fun)


  def slice( mag) do
    # map = GenServer.call( pid( mag), :map_copy)
    # slicing_fun = fn start, length ->
    #   Enum.reduce map, [], fn
    #     {key, {state,_,_}}, acc ->
    #       acc
    #     {key, {{:state, state},_,_}}, acc ->
    #       {key, state}
    #     {key, {:pid, worker}}, acc ->
    #       dict = Process.info( worker, :dictionary)
    #       unless dict do
    #         # worker died, state stored in a map,
    #         # need to ask server for it
    #         MultiAgent.fetch mag, key
    #       else
    #         {:dictionary, dict} = dict
    #         Keyword.fetch dict, :'$state'
    #       end
    #   end
    # end

    # {:ok, map_size( map), slicing_fun}

    {:error, __MODULE__}
  end
end

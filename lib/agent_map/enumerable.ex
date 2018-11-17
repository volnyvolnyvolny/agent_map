defimpl Enumerable, for: AgentMap do
  import AgentMap

  def count(am) do
    {:ok, get_prop(am, :size)}
  end

  def member?(am, {key, value}) do
    {:ok, match?({:ok, ^value}, fetch(am, key))}
  end

  def slice(am) do
    map = to_map(am)
    {:ok, map_size(map), &Enumerable.List.slice(:maps.to_list(map), &1, &2)}
  end

  def reduce(am, acc, fun) do
    am
    |> to_map()
    |> :maps.to_list()
    |> reduce_list(acc, fun)
  end

  defp reduce_list(_, {:halt, acc}, _fun), do: {:halted, acc}
  defp reduce_list([], {:cont, acc}, _fun), do: {:done, acc}

  defp reduce_list([h | t], {:cont, acc}, fun) do
    reduce_list(t, fun.(h, acc), fun)
  end

  defp reduce_list(list, {:suspend, acc}, fun) do
    {:suspended, acc, &reduce_list(list, &1, fun)}
  end
end

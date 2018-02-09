defimpl Enumerable, for: MultiAgent do
  import MultiAgent


  def count(%MultiAgent{link: mag}) do
    {:ok, GenServer.call( mag, :count)}
  end


  def member?( mag, {key,state}) do
    case fetch( mag, key) do
      {:ok, ^state} -> {:ok, true}
      _ -> {:ok, false}
    end
  end

  def slice( mag) do
    map = take mag, keys mag
    {:ok, map_size(map), &Enumerable.List.slice(:maps.to_list(map), &1, &2)}
  end

  def reduce( map, acc, fun) do
    map = take mag, keys mag
    reduce_list(:maps.to_list(map), acc, fun)
  end

  defp reduce_list(_, {:halt, acc}, _fun), do: {:halted, acc}
  defp reduce_list(list, {:suspend, acc}, fun), do: {:suspended, acc, &reduce_list(list, &1, fun)}
  defp reduce_list([], {:cont, acc}, _fun), do: {:done, acc}
  defp reduce_list([h | t], {:cont, acc}, fun), do: reduce_list(t, fun.(h, acc), fun)
end

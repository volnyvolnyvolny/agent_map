defimpl Collectable, for: AgentMap do
  def into(original) do
    collector_fun = fn
      am, {:cont, {key, value}} ->
        AgentMap.put(am, key, value)

      am, :done ->
        am

      _set, :halt ->
        :ok
    end

    {original, collector_fun}
  end
end

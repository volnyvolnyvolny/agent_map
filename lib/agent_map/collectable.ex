defimpl Collectable, for: AgentMap do
  def into(am) do
    collector_fun = fn
      am, {:cont, {key, value}} ->
        AgentMap.put(am, key, value, cast: false)

      am, :done ->
        am

      _set, :halt ->
        :ok
    end

    {am, collector_fun}
  end
end

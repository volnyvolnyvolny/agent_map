defmodule AgentMap.CallbackError do
  defexception [:got, :len, transaction?: false]

  def message(%{transaction?: false, got: g}) do
    """
    callback may return {get, value} | {get} | :id | :pop | {fun, keys}, value}.
    got: #{inspect(g)}
    """
  end

  def message(%{transaction?: true, len: n}) do
    "the number of returned values #{n} does not equal to the number of keys"
  end

  def message(%{transaction?: true, got: g}) do
    """
    callback may return {get, [value] | :id | :drop} | {get} | :id | :pop |
    [{get, value} | {get} | :id | :pop].
    got: #{inspect(g)}
    """
  end
end

defmodule AgentMap.IncError do
  defexception [:key, :value, :step]

  def message(%{step: s, key: k, value: v}) when s > 0 do
    "cannot increment key #{inspect(k)} because it has a non-numerical value #{inspect(v)}"
  end

  def message(%{key: k, value: v}) do
    "cannot decrement key #{inspect(k)} because it has a non-numerical value #{inspect(v)}"
  end
end

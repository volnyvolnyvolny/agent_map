defmodule AgentMap.CallbackError do
  defexception [:got, :len, multi_key?: false]

  def message(%{multi_key?: false, got: g}) do
    """
    callback may return {get, value} | {get} | :id | :pop | {fun, keys}, value}.
    got: #{inspect(g)}
    """
  end

  def message(%{multi_key?: true, got: g}) do
    """
    callback may return {get, [value] | :id | :drop} | {get} | :id | :pop |
    [{get, value} | {get} | :id | :pop].
    got: #{inspect(g)}
    """
  end

  def message(%{len: n}) when is_integer(n) do
    "the number of returned values #{n} does not equal to the number of keys"
  end
end

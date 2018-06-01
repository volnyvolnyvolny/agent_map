defmodule AgentMap.MalformedCallback do
  defexception [:for, :len, :got, transaction?: false]

  def message(%{transaction?: false, for: :get_and_update} = exception) do
    "callback expected to return :id | :pop | {get} | {get, value} | {:chain,
    {key, fun} | {fun, keys}, value, got: #{exception.got}"
  end

  def message(%{transaction?: true, len: l} = exception) when is_integer(l) do
    "callback expected to return #{l} updated values, got: #{exception.got}"
  end

  def message(%{transaction?: true, for: :get_and_update} = exception) do
    "callback expected to return :id | :pop | {get} | {get, value} | {:chain,
    {key, fun} | {fun, keys}, value, got: #{exception.got}"
  end

  def message(%{transaction?: true} = exception) do
    """
      callback expected to return :id | :pop | {get}
      | {get, [value] | :id | :drop} | [{get} | {get, value} | :id | :pop]
      | {:chain, {key, fun} | {fun, keys}, value}, got: #{exception.got}
    """
    |> String.replace("\n", " ")
  end
end

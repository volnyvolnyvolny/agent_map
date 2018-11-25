defmodule AgentMap.CallbackError do
  defexception [:got, :pos, :item, :len, :expected, multi_key?: false]

  # single-key

  def message(%{multi_key?: false, got: got}) do
    """
    callback may return:

      * {get, value}
      * {get}
      * :pop
      * :id

    got: #{inspect(got)}
    """
  end

  # multi-key

  def message(%{got: got, pos: n} = e) when is_integer(n) do
    message(%{multi_key?: true, got: got}) <>
      """

      err-item: #{inspect(e.item)}
      position: #{n}
      """
  end

  def message(%{len: n, expected: e}) when is_integer(n) do
    message(%{multi_key?: true, got: got}) <>
      """

      expected #{e} elements, got #{n}
      """
  end

  def message(%{multi_key?: true, got: got}) do
    """
    callback may return:

      * {get, [value] | :id | :drop}
      * [{get, value} | {get} | :id | :pop]

      * {get} = {get, :id}
      * :id   = [:id, …]
      * :pop  = [:pop, …]

    got: #{inspect(got)}
    """
  end
end

defmodule AgentMap.CallbackError do
  defexception [:got, :pos, :item, :len, :expected, multi_key?: false]

  # single-key

  def message(%{multi_key?: false, got: got}) do
    """
    "get_and_update"-callback can return:

      * {get, value}
      * {get}
      * :pop
      * :id

    Got: #{inspect(got)}
    """
  end

  # multi-key

  def message(%{got: got, pos: n} = e) when is_integer(n) do
    message(%{multi_key?: true, got: got}) <>
      """

      Err-item: #{inspect(e.item)}
      Position: #{n}
      """
  end

  def message(%{len: n, expected: e} = exc) when is_integer(n) do
    message(%{multi_key?: true, got: exc.got}) <>
      """

      expected #{e} elements, got #{n}
      """
  end

  def message(%{multi_key?: true, got: got}) do
    """
    "get_and_update"-callback can return:

      * {get, [value] | :id | :drop | map}
      * [{get, value} | {get} | :id | :pop]

      * {get} = {get, :id}
      * :id   = [:id, …]
      * :pop  = [:pop, …]

    Got: #{inspect(got)}
    """
  end
end

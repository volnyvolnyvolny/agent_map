defmodule AgentMapMultiTest do
  use ExUnit.Case

  import :timer
  import AgentMap.Utils, only: [sleep: 3]
  import AgentMap, only: [put: 3]
  import AgentMap.Multi

#  doctest AgentMap.Multi, import: true

  test "…" do
    assert AgentMap.new(a: 6)
           |> sleep(:a, 20)
           |> put(:a, 1)
           |> update([:a, :b], fn [1, 1] -> [2, 2] end, initial: 1)
           |> update([:a, :b], fn [2, 2] -> [3, 3] end)
           |> get([:a, :b])

    [3, 3]
  end
end

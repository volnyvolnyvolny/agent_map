defmodule AgentMapMultiTest do
  use ExUnit.Case

  import :timer
  import AgentMap.Utils, only: [sleep: 3]
  import AgentMap, only: [put: 3]
  #  import AgentMap.Multi

  doctest AgentMap.Multi, import: true

  # test "…" do
  #   # assert AgentMap.new()
  #   # |> sleep(:a, 30)                                                         # 0 | | |
  #   # |> put(:a, 3)                                                            # | | 2 |
  #   # |> put(:b, 0)                                                            # | | 2 |
  #   # |> update([:a, :b], fn [1, 0] -> [2, 2] end, !: {:max, +1}, initial: 1)  # | 1 | |
  #   # |> update([:a, :b], fn [3, 2] -> [4, 4] end)                             # | | | 3
  #   # |> get([:a, :b]) ==      [4, 4]
  # end
end

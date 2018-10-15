defmodule AgentMapTest do
  import AgentMap
  import :timer

  use ExUnit.Case
  doctest AgentMap

  test "put" do
    # assert %{a: 1}
    #        |> AgentMap.new()
    #        |> put(:a, 42)
    #        |> put(:b, 42)
    #        |> take([:a, :b]) == %{a: 42, b: 42}

    # Process.flag(:trap_exit, true)

    # am =
    #   %{a: 1}
    #   |> AgentMap.new()
    #   |> sleep(:a, 20)
    #   |> put(:a, 2)
    #   |> put(:a, 4, !: :avg)
    #   |> put(:a, 8, !: :avg, timeout: {:!, 10})

    # # ⏺ ⟶ s ⟶ p ⟶ p ⟶̸ p̶
    # assert fetch(am, :a) == {:ok, 1}
    # # s ⟶ p ⟶ ⏺ ⟶ p ⟶̸ p̶
    # assert fetch(am, :a, !: :max) == {:ok, 2}
    # # s ⟶ p ⟶ p ⟶ ⏺ ⟶̸ p̶
    # assert fetch(am, :a, !: :min) == {:ok, 4}
  end

  test "get" do
    # am = AgentMap.new(Alice: 42)
    # assert AgentMap.get(am, :Alice) ==
    # 42
    # assert AgentMap.get(am, :Bob) ==
    # nil

    # assert %{Alice: 42}
    # |> AgentMap.new()
    # |> AgentMap.sleep(:Alice, 10)
    # |> AgentMap.put(:Alice, 0)
    # |> AgentMap.get(:Alice) ==
    # 0
  end
end

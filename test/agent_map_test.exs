defmodule AgentMapTest do
  use ExUnit.Case

  import :timer
  import AgentMap
  import AgentMap.Utils

  doctest AgentMap, import: true

  # test "…" do
  #   # am =
  #   #   AgentMap.new(a: 1, b: 2, c: 3)

  #   # assert am
  #   # |> sleep(:a, 100, !: :max)
  #   # |> put(:a, 42)
  #   # |> sleep(:b, 100, !: :max)
  #   # |> put(:b, 42)
  #   # |> take([:a, :b, :d]) == %{a: 1, b: 2}
  # end

  test "Collectable" do
    am = AgentMap.new()

    proc = fn c ->
      1..1000
      |> Enum.map(&{&1, 1 / &1})
      |> Enum.into(c)
    end

    map = proc.(%{})
    am = proc.(am)

    assert to_map(am) == map
  end

  test "delete" do
    assert AgentMap.new(a: 1)
           |> sleep(:a, 20)
           |> delete(:a, !: :min)
           |> put(:a, 2)
           |> get(:a) == nil
  end
end

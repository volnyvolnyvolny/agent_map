defmodule MultiAgentTest do
  use ExUnit.Case
  doctest MultiAgent

  test "new" do
    # mag = MultiAgent.new
    # assert Enum.empty?( mag)

    mag = MultiAgent.new( a: 42, b: 24)
    assert mag[:a] == 42
    assert MultiAgent.keys(mag) == [:a, :b]
    {:ok, pid} = MultiAgent.start_link()

    mag = MultiAgent.new pid
    assert MultiAgent.init( mag, :a, fn -> 1 end) == {:ok, 1}
    assert mag[:a] == 1

    mag = MultiAgent.new [:a, :b], fn x -> {x, x} end
    assert MultiAgent.take( mag, [:a, :b]) == %{a: :a, b: :b}
  end
end

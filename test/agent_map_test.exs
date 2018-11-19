defmodule AgentMapTest do
  use ExUnit.Case

  import :timer
  import AgentMap

  doctest AgentMap, import: true

  test "size" do
    am = AgentMap.new()

    assert am
           |> sleep(:a, 20)
           |> get_prop(:size) == 1

    sleep(100)
    assert get_prop(am, :size) == 0
  end
end

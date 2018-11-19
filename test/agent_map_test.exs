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

  test "delete" do
    assert AgentMap.new(a: 1)
           |> sleep(:a, 20)
           |> delete(:a, !: :min)
           |> put(:a, 2)
           |> get(:a) == nil
  end

  test "max_processes" do
    am = AgentMap.new()

    assert info(am, :key)[:max_processes] == 5

    max_processes(am, :key, 3)
    assert info(am, :key)[:max_processes] == 3

    max_processes(am, :key, nil)
    assert info(am, :key)[:max_processes] == 5
  end
end

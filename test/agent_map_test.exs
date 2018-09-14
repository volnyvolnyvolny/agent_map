defmodule AgentMapTest do
  import AgentMap
  # import :timer

  use ExUnit.Case
  #  doctest AgentMap

  test "main" do
    am = AgentMap.new(a: 1, b: 2)

    assert am
           |> AgentMap.delete(:a)
           |> AgentMap.take([:a, :b]) == %{b: 2}

    # assert am
    #        |> AgentMap.delete(:b)
    #        |> AgentMap.take([:a, :b]) == %{b: 2}

    # #
    # assert am
    #        |> AgentMap.take(am, [:a, :b], !: false) == %{}

    # import AgentMap
    # am = AgentMap.new()
    # assert max_processes(am, :k, 42) == 5
    # assert max_processes(am, :k, :infinity) == 42

    # #

    # import :timer
    # assert am
    # |> cast(:k, fn _ -> sleep(100) end)
    # |> max_processes(:k, 42, !: true) == :infinity

    # assert max_processes(am, :k, 1, !: true) == :infinity
    # assert max_processes(am, :k, :infinity) == 1
  end
end

defmodule AgentMapTest do
  import AgentMap
  # import :timer

  use ExUnit.Case
#  doctest AgentMap

  test "main" do
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

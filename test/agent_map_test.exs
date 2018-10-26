defmodule AgentMapTest do
  use ExUnit.Case

  import :timer
  doctest AgentMap, import: true, only: [max_processes: 3]
end

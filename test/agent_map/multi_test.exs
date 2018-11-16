defmodule AgentMapMultiTest do
  use ExUnit.Case

  import :timer
  import AgentMap, only: [sleep: 3, put: 3]

  doctest AgentMap.Multi, import: true
end

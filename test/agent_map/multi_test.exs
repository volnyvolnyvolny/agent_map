defmodule AgentMapMultiTest do
  use ExUnit.Case

  import :timer
  doctest AgentMap.Multi, import: true, only: [cast: 4]
end

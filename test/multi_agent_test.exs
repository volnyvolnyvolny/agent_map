defmodule MultiAgentTest do
  use ExUnit.Case
  doctest MultiAgent

  test "greets the world" do
    assert MultiAgent.hello() == :world
  end
end

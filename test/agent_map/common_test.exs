defmodule AgentMapCommonTest do
  import AgentMap.Common

  use ExUnit.Case

  test "run" do
    assert run(&(&1 * 2), [1], :infinity) == {:ok, 2}
    assert run(&(&1 * 2), [1], 100) == {:ok, 2}
    assert run(&(&1 * 2), [1], 1) == {:ok, 2}
    assert run(&(&1 * 2), [1], 0) == {:error, :expired}
    assert run(&(&1 * 2), [1], -1) == {:error, :expired}
  end
end

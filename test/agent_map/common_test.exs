defmodule AgentMapCommonTest do
  import AgentMap.Common

  use ExUnit.Case

  test "run" do
    fun = &(&1 * 2)
    assert run(fun, [1], :infinity, false) == {:ok, 2}
    assert run(fun, [1], 100, false) == {:ok, 2}

    # drop
    assert run(fun, [1], 1, false) == {:ok, 2}
    assert run(fun, [1], 0, false) == {:error, :expired}
    assert run(fun, [1], -1, false) == {:error, :expired}

    fun = fn v ->
      :timer.sleep(10)
      v * 2
    end

    # break
    assert run(fun, [1], 1, true) == {:error, :toolong}
    assert run(fun, [1], 0, true) == {:error, :expired}
    assert run(fun, [1], -1, true) == {:error, :expired}
    assert run(fun, [1], 8, true) == {:error, :toolong}
    assert run(fun, [1], 11, true) == {:ok, 2}
  end
end

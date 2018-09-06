defmodule AgentMapCommonTest do
  import AgentMap.Common

  use ExUnit.Case

  test "run" do
    assert(run(&(&1 * 2), [1]) == {:ok, 2})
    assert(run(&(&1 * 2), [1], timeout: 100, inserted_at: now()) == {:ok, 2})

    # drop
    past = now()
    :timer.sleep(10)
    assert(run(&(&1 * 2), [1], timeout: 11, inserted_at: past) == {:ok, 2})
    assert(run(&(&1 * 2), [1], timeout: 9, inserted_at: past) == {:error, :expired})

    fun = fn v ->
      :timer.sleep(10)
      v * 2
    end

    # break
    assert(run(fun, [1], timeout: 11, inserted_at: now(), break: true) == {:ok, 2})

    past = now()
    :timer.sleep(2)
    assert(run(fun, [1], timeout: 11, inserted_at: past, break: true) == {:error, :toolong})

    past = now()
    :timer.sleep(2)
    assert(run(fun, [1], timeout: 13, inserted_at: past, break: true) == {:ok, 2})

    assert(run(fun, [1], timeout: 9, inserted_at: now(), break: true) == {:error, :toolong})
  end
end

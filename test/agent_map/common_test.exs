defmodule AgentMapCommonTest do
  import AgentMap.Common

  use ExUnit.Case

  defp opts(t, i, b? \\ nil) do
    %{timeout: t, inserted_at: i, break: b?}
  end

  defp ms(), do: 1_000_000

  test "run" do
    fun = &(&1 * 2)
    assert(run(fun, [1]) == {:ok, 2})
    assert(run(fun, [1], opts(100, now())) == {:ok, 2})

    # drop
    assert(run(fun, [1], opts(11, now() - 10 * ms())) == {:ok, 2})
    assert(run(fun, [1], opts(9, now() - 10 * ms())) == {:error, :expired})

    fun = fn v ->
      :timer.sleep(10)
      v * 2
    end

    # break
    assert(run(fun, [1], opts(11, now(), true)) == {:ok, 2})
    assert(run(fun, [1], opts(11, now() - 3 * ms(), true)) == {:error, :toolong})
    assert(run(fun, [1], opts(13, now() - 2 * ms(), true)) == {:ok, 2})
    assert(run(fun, [1], opts(9, now(), true)) == {:error, :toolong})
  end
end

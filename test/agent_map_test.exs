defmodule AgentMapTest do
  import AgentMap
  import :timer

  use ExUnit.Case
  # doctest AgentMap

  test "main" do
    Process.flag(:trap_exit, true)

    am = AgentMap.new(key: 42)

    # am
    # |> cast(:key, fn v -> sleep(50); v - 9 end)
    # |> put(:key, 24, timeout: 10)

    # IO.inspect(queue_len(am, :key))

    # # IO.inspect(Process.info(self())[:message_queue_len])
    # # IO.inspect(get(am, :key))
    # # assert(Process.info(self())[:message_queue_len], 1)
    # # assert(get(am, :key), 42)
    # # assert(get(am, :key, !: false), 24)
  end
end

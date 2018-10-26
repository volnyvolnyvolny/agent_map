defmodule AgentMapWorkerTest do
  alias AgentMap.{Worker, Server.State}
  import State

  use ExUnit.Case

  import :timer

  def a <~> b, do: (a - b) in -1..1

  test "spawn_get_task" do
    fun = fn value ->
      sleep(10)
      key = Process.get(:key)
      box = Process.get(:value)

      {value, {key, box}}
    end

    msg = %{act: :get, from: {self(), :_}, fun: fun}

    b = box(42)
    Worker.spawn_get_task(msg, {:key, b})
    assert_receive {:_, {42, {:key, ^b}}}
    assert_receive %{info: :done, key: :key}

    Worker.spawn_get_task(msg, {:key, nil})
    assert_receive {:_, {nil, {:key, nil}}}
    assert_receive %{info: :done, key: :key}
  end
end

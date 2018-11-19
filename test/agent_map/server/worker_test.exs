defmodule AgentMapWorkerTest do
  alias AgentMap.Worker

  use ExUnit.Case

  import :timer

  def a <~> b, do: (a - b) in -1..1

  test "spawn_get_task" do
    fun = fn arg ->
      sleep(10)
      key = Process.get(:key)
      value? = Process.get(:value?)

      {arg, {key, value?}}
    end

    msg = %{act: :get, from: {self(), :_}, fun: fun}

    v? = {:v, 42}
    Worker.spawn_get_task(msg, {:key, v?})
    assert_receive {:_, {42, {:key, ^v?}}}
    assert_receive %{info: :done, key: :key}

    Worker.spawn_get_task(msg, {:key, nil})
    assert_receive {:_, {nil, {:key, nil}}}
    assert_receive %{info: :done, key: :key}
  end
end

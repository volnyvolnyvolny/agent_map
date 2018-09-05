defmodule AgentMapWorkerTest do
  alias AgentMap.{Worker, Server.State}

  use ExUnit.Case

  test "run_and_reply" do
    state =
      {%{}, 7}
      |> put(:a, box(42))
      |> put(:b, {box(1), 4})
      |> put(:c, {box(4), {1, 6}})
      |> put(:d, {nil, 5})
      |> spawn_worker(:b)
      |> spawn_worker(:c)

    Worker.run_and_reply()
  end

  test "get_and_update" do
    assert false
  end

  test "get" do
    assert false
  end

  test "max_processes" do
    assert false
  end

  test "selective receive" do
    assert false
  end

  test ":get!" do
    assert false
  end

  test ":done" do
    assert false
  end
end

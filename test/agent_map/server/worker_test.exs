defmodule AgentMapWorkerTest do
  alias AgentMap.{Req, Worker, Server.State}
  import State

  use ExUnit.Case

  test "run_and_reply" do
    fun = &{&1, :there}
    req = %Req{action: :get, from: {self(), :_}, data: {:_, fun}}
    msg = Req.compress(req)
    Worker.run_and_reply(fun, :hi, msg)
    assert_received {:_, {:hi, :there}}

    msg = Req.to_msg(req, :get_and_update, &{:ok, &1 * 2})
    Worker.run_and_reply(fun, 1, msg)
    assert Process.get(:"$value") == {:value, 2}
    assert_received {:_, :ok}
  end

  test "get_and_update" do
    state =
      {%{}, 7}
      |> put(:a, box(42))
      |> put(:b, {box(1), 4})
      |> put(:c, {box(4), {1, 6}})
      |> put(:d, {nil, 5})
      |> spawn_worker(:b)
      |> spawn_worker(:c)

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

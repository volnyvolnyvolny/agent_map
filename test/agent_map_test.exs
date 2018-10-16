defmodule AgentMapTest do
  import AgentMap
  import :timer

  use ExUnit.Case
  doctest AgentMap, import: true, only: [info: 2]

  test "safe_apply" do
    # import System, only: [system_time: 1]

    # Process.flag(:trap_exit, true)
    # am = AgentMap.new(a: 42) |> sleep(:a, 10)

    # past = system_time(:milliseconds)

    # slow_call = fn _v ->
    #   :timer.sleep(5000)
    #   "5 sec. after"
    # end

    # fun = fn arg ->
    #   case safe_apply(slow_call, [arg], system_time(:milliseconds) - past) do
    #     {:ok, res} ->
    #       {res, res}

    #     {:error, :timeout} ->
    #       :id

    #     {:error, reason} ->
    #       raise reason
    #   end
    # end

    # #    IO.inspect(safe_apply(&get_and_update/4, [am, :a, fun, timeout: {:!, 20}]))

    # try do
    #   assert am
    #          |> get_and_update(:a, fun, timeout: {:!, 20})
    # catch
    #   :exit, reason ->
    #     IO.inspect(reason)
    # end

    # # :timer.sleep(100)

    # # IO.inspect(:x)
    # # assert Process.info(self())[:message_queue_len] == 1

    # # IO.inspect(:x)

    # # :timer.sleep(100)
  end

  test "inc" do
    # am = AgentMap.new(a: 1.5)

    # assert am
    # |> inc(:a, step: 1.5)
    # |> inc(:b)
    # |> get(:a) == 3

    # assert get(am, :b) == 1

    # Process.flag(:trap_exit, true)

    # assert_raise inc(am, :c, initial: false, cast: false)

    # sleep(100)

    #    Process.info()[:message_queue_len] |> IO.inspect()
  end

  test "put" do
    # assert %{a: 1}
    #        |> AgentMap.new()
    #        |> put(:a, 42)
    #        |> put(:b, 42)
    #        |> take([:a, :b]) == %{a:...>  42, b: 42}

    # Process.flag(:trap_exit, true)

    # am =
    #   %{a: 1}
    #   |> AgentMap.new()
    #   |> sleep(:a, 20)
    #   |> put(:a, 2)
    #   |> put(:a, 4, !: :avg)
    #   |> put(:a, 8, !: :avg, timeout: {:!, 10})

    # # ⏺ ⟶ s ⟶ p ⟶ p ⟶̸ p̶
    # assert fetch(am, :a) == {:ok, 1}
    # # s ⟶ p ⟶ ⏺ ⟶ p ⟶̸ p̶
    # assert fetch(am, :a, !: :max) == {:ok, 2}
    # # s ⟶ p ⟶ p ⟶ ⏺ ⟶̸ p̶
    # assert fetch(am, :a, !: :min) == {:ok, 4}
  end

  test "get" do
    # am = AgentMap.new(Alice: 42)
    # assert AgentMap.get(am, :Alice) ==
    # 42
    # assert AgentMap.get(am, :Bob) ==
    # nil

    # assert %{Alice: 42}
    # |> AgentMap.new()
    # |> AgentMap.sleep(:Alice, 10)
    # |> AgentMap.put(:Alice, 0)
    # |> AgentMap.get(:Alice) ==
    # 0
  end
end

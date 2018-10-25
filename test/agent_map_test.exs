defmodule AgentMapTest do
  import AgentMap
  import :timer

  use ExUnit.Case
  doctest AgentMap, import: true#, only: [drop: 3]

  # test "take" do
  #     am =
  #       AgentMap.new(a: 1, b: 2, c: 3)
  #     assert am
  #     |> sleep(:a, 100)
  #     |> put(:a, 42)
  #     |> put(:a, 0, !: :avg)
  #     |> sleep(:b, 100)
  #     |> put(:b, 42)
  #     |> take([:a, :b, :d], !: :now) ==
  #     %{a: 1, b: 2}
  #     # assert take(am, [:a, :b, :d], !: :max) ==
  #     # %{a: 42, b: 42}
  #     # assert take(am, [:a, :b, :d]) ==
  #     # %{a: 0, b: 42}
  # end

  test "values" do
    # am =
    #   %{a: 1, b: 2, c: 42}
    #   |> AgentMap.new()
    #   |> sleep(:a, 10)
    #   |> put(:a, 42,     !: {:max, +1})
    #   |> put(:a, 0)    # !: :max
    #   |> put(:a, 24,     !: :min)
    #   |> sleep(:b, 10)
    #   |> put(:b, 42)   # !: :max

    # assert values(am, !: {:max, +1}) ==
    # [42, 2, 42]
    # assert values(am, !: :max) ==
    # [0, 42, 42]
    # assert values(am, !: :min) ==
    # [42, 42, 42]
  end

  test "prior" do
    # IO.inspect(:prior)
    # am =
    #   AgentMap.new(state: :ready)

    # max_processes(am, :state, 1)

    # assert am
    # |> sleep(:state, 100)
    # |> cast(:state, fn :go! -> :stop end)                     # 3
    # |> cast(:state, fn :steady -> :go! end, !: :max)          # 2
    # |> cast(:state, fn :ready  -> :steady end, !: {:max, +1}) # 1
    # |> fetch(:state) ==
    # {:ok, :ready}

    # assert fetch(am, :state, !: {:max, +1}) ==
    # {:ok, :steady}
    # assert fetch(am, :state, !: :max) ==
    # {:ok, :go!}
    # assert fetch(am, :state, !: :avg) ==
    # {:ok, :stop}
  end

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

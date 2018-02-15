defmodule MultiAgentTest do
  use ExUnit.Case
#  doctest MultiAgent

  test "new" do
    # mag = MultiAgent.new
    # assert Enum.empty? mag

    # mag = MultiAgent.new( a: 42, b: 24)
    # assert mag[:a] == 42
    # assert MultiAgent.keys(mag) == [:a, :b]
    # {:ok, pid} = MultiAgent.start_link()

    # mag = MultiAgent.new pid
    # assert MultiAgent.init( mag, :a, fn -> 1 end) == {:ok, 1}
    # assert mag[:a] == 1

    # mag = MultiAgent.new [:a, :b], fn x -> {x, x} end
    # assert MultiAgent.take( mag, [:a, :b]) == %{a: :a, b: :b}
  end

  test "start_link" do
#     {:ok, pid} = MultiAgent.start_link key: fn -> 42 end
#     assert 42 == MultiAgent.get pid, :key, & &1
# #    IO.inspect(:sys.get_status( pid))
# #    IO.inspect(:sys.get_state( pid), label: "GS state")
#     assert nil == MultiAgent.get pid, :nosuchkey, & &1
  end

  test "start" do
    # assert MultiAgent.start( one: 42,
    #                          two: fn -> :timer.sleep(150) end,
    #                          three: fn -> :timer.sleep(:infinity) end,
    #                          timeout: 100) ==
    #        {:error, [one: :cannot_call, two: :timeout, three: :timeout]}

    # assert MultiAgent.start( one: :foo,
    #                          one: :bar,
    #                          three: fn -> :timer.sleep(:infinity) end,
    #                          timeout: 100) ==
    #        {:error, [one: :already_exists]}

    # err = MultiAgent.start one: 76, two: fn -> raise "oops" end
    # {:error, [one: :cannot_call, two: {exception, _stacktrace}]} = err
    # assert exception == %RuntimeError{ message: "oops"}
  end

  test "get_and_update" do
    # import MultiAgent
    # mag = new uno: 22, dos: 24, tres: 42, cuatro: 44
    # assert 22 == get_and_update mag, :uno, & {&1, &1 + 1}
    # assert 23 == get mag, :uno, & &1

    # assert 42 == get_and_update mag, :tres, fn _ -> :pop end
    # assert nil == get mag, :tres, & &1

    # assert [23, 24, nil, 44] == get mag, & &1, [:uno, :dos, :tres, :cuatro]


    # #
    # # transaction calls:
    # # 
    # assert [23, 24] == get_and_update mag, fn [u, d] ->
    #   [{u, d}, {d, u}]
    # end, [:uno, :dos]
    # assert [24,23] == get mag, & &1, [:uno, :dos]

    # assert [23] == get_and_update mag, fn _ -> :pop end, [:dos]

    # assert [24, nil, nil, 44] == get mag, & &1, [:uno, :dos, :tres, :cuatro]

    # assert [24, nil, :_, 44] == get_and_update mag, fn _ ->
    #   [:id, {nil, :_}, {:_, nil}, :pop]
    # end, [:uno, :dos, :tres, :cuatro]

    # assert [24, :_, nil, nil] == get mag, & &1, [:uno, :dos, :tres, :cuatro]
  end

  test "update" do
    # mag = MultiAgent.new alice: 42, bob: 24, chris: 33, dunya: 51
    # assert :ok == MultiAgent.update mag, &Enum.reverse/1, [:alice, :bob]
    # assert [24, 42] == MultiAgent.get mag, & &1, [:alice, :bob]
    # assert :ok == MultiAgent.update mag, fn _ -> :drop end, [:alice, :bob]

    # assert [:chris, :dunya] == MultiAgent.keys mag
    # MultiAgent.update mag, fn _ -> :drop end, [:chris]
    # # but:
    # MultiAgent.update mag, :dunya, fn _ -> :drop end
    # assert [nil, :drop] == MultiAgent.get mag, & &1, [:chris, :dunya]
  end

  test "get/2" do
    # mag = MultiAgent.new()
    # assert [nil,nil] == MultiAgent.get mag, alice: & &1, bob: & &1
    # assert :ok == MultiAgent.update mag, alice: fn nil -> 42 end,
    #                               bob:   fn nil -> 24 end
    # assert [42, 24] == MultiAgent.get mag, alice: & &1, bob: & &1
    # MultiAgent.update mag, alice: & &1-10, bob: & &1+10
    # assert [32, 34] == MultiAgent.get mag, alice: & &1, bob: & &1
  end

  test "put/3" do
    # mag = MultiAgent.new a: 1
    # MultiAgent.put( mag, :b, 2)
    # assert %{a: 1, b: 2} == MultiAgent.take(mag, [:a, :b])
    # MultiAgent.put( mag, :a, 3)
    # assert %{a: 3, b: 2} == MultiAgent.take(mag, [:a, :b])
  end

  test "get/5" do
    # mag = MultiAgent.new key: 42
    # MultiAgent.cast mag, :key, fn _ ->
    #   :timer.sleep( 100)
    #   43
    # end
    # # %{link: pid} = mag
    # # IO.inspect :sys.get_state pid
    # assert 42 == MultiAgent.get mag, :!, :key, & &1
    # assert 42 == mag[:key]
    # assert 43 == MultiAgent.get mag, :key, & &1
    # assert 43 == MultiAgent.get mag, :!, :key, & &1
  end

  test "init" do
    mag = MultiAgent.new()
    assert nil == MultiAgent.get mag, :k, & &1
    assert {:ok, 42} == MultiAgent.init mag, :k, fn -> 42 end
    assert 42 == MultiAgent.get mag, :k, & &1
    assert {:error, {:k, :already_exists}} == MultiAgent.init mag, :k, fn -> 43 end
    assert {:error, :timeout} == MultiAgent.init mag, :_, fn -> :timer.sleep(300) end, timeout: 200
    assert {:error, {:k, :already_exists}} == MultiAgent.init mag, :k, fn -> :timer.sleep(300) end, timeout: 200
    assert {:ok, 42} == MultiAgent.init mag, :k2, fn -> 42 end, late_call: false

    MultiAgent.cast mag, :k2, & :timer.sleep(100) && &1 #blocks for 100 ms

    assert {:error, :timeout} == MultiAgent.update mag, :k, fn _ -> 0 end, 50
    assert 42 == MultiAgent.get mag, :k, & &1 #update was not happend
  end
end

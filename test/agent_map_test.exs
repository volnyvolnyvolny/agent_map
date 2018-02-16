defmodule AgentMapTest do
  use ExUnit.Case
  doctest AgentMap

  test "new" do
    # mag = AgentMap.new
    # assert Enum.empty? mag

    # mag = AgentMap.new( a: 42, b: 24)
    # assert mag[:a] == 42
    # assert AgentMap.keys(mag) == [:a, :b]
    # {:ok, pid} = AgentMap.start_link()

    # mag = AgentMap.new pid
    # assert AgentMap.init( mag, :a, fn -> 1 end) == {:ok, 1}
    # assert mag[:a] == 1

    # mag = AgentMap.new [:a, :b], fn x -> {x, x} end
    # assert AgentMap.take( mag, [:a, :b]) == %{a: :a, b: :b}
  end

  test "start_link" do
#     {:ok, pid} = AgentMap.start_link key: fn -> 42 end
#     assert 42 == AgentMap.get pid, :key, & &1
# #    IO.inspect(:sys.get_status( pid))
# #    IO.inspect(:sys.get_state( pid), label: "GS state")
#     assert nil == AgentMap.get pid, :nosuchkey, & &1
  end

  test "start" do
    # assert AgentMap.start( one: 42,
    #                          two: fn -> :timer.sleep(150) end,
    #                          three: fn -> :timer.sleep(:infinity) end,
    #                          timeout: 100) ==
    #        {:error, [one: :cannot_call, two: :timeout, three: :timeout]}

    # assert AgentMap.start( one: :foo,
    #                          one: :bar,
    #                          three: fn -> :timer.sleep(:infinity) end,
    #                          timeout: 100) ==
    #        {:error, [one: :already_exists]}

    # err = AgentMap.start one: 76, two: fn -> raise "oops" end
    # {:error, [one: :cannot_call, two: {exception, _stacktrace}]} = err
    # assert exception == %RuntimeError{ message: "oops"}
  end

  test "get_and_update" do
    # import AgentMap
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
    # mag = AgentMap.new alice: 42, bob: 24, chris: 33, dunya: 51
    # assert :ok == AgentMap.update mag, &Enum.reverse/1, [:alice, :bob]
    # assert [24, 42] == AgentMap.get mag, & &1, [:alice, :bob]
    # assert :ok == AgentMap.update mag, fn _ -> :drop end, [:alice, :bob]

    # assert [:chris, :dunya] == AgentMap.keys mag
    # AgentMap.update mag, fn _ -> :drop end, [:chris]
    # # but:
    # AgentMap.update mag, :dunya, fn _ -> :drop end
    # assert [nil, :drop] == AgentMap.get mag, & &1, [:chris, :dunya]
  end

  test "get/2" do
    # mag = AgentMap.new()
    # assert [nil,nil] == AgentMap.get mag, alice: & &1, bob: & &1
    # assert :ok == AgentMap.update mag, alice: fn nil -> 42 end,
    #                               bob:   fn nil -> 24 end
    # assert [42, 24] == AgentMap.get mag, alice: & &1, bob: & &1
    # AgentMap.update mag, alice: & &1-10, bob: & &1+10
    # assert [32, 34] == AgentMap.get mag, alice: & &1, bob: & &1
  end

  test "put/3" do
    # mag = AgentMap.new a: 1
    # AgentMap.put( mag, :b, 2)
    # assert %{a: 1, b: 2} == AgentMap.take(mag, [:a, :b])
    # AgentMap.put( mag, :a, 3)
    # assert %{a: 3, b: 2} == AgentMap.take(mag, [:a, :b])
  end

  test "get/5" do
    # mag = AgentMap.new key: 42
    # AgentMap.cast mag, :key, fn _ ->
    #   :timer.sleep( 100)
    #   43
    # end
    # # %{link: pid} = mag
    # # IO.inspect :sys.get_state pid
    # assert 42 == AgentMap.get mag, :!, :key, & &1
    # assert 42 == mag[:key]
    # assert 43 == AgentMap.get mag, :key, & &1
    # assert 43 == AgentMap.get mag, :!, :key, & &1
  end

  # test "init" do
  #   mag = AgentMap.new()
  #   assert nil == AgentMap.get mag, :k, & &1
  #   assert {:ok, 42} == AgentMap.init mag, :k, fn -> 42 end
  #   assert 42 == AgentMap.get mag, :k, & &1
  #   assert {:error, {:k, :already_exists}} == AgentMap.init mag, :k, fn -> 43 end
  #   assert {:error, :timeout} == AgentMap.init mag, :_, fn -> :timer.sleep(300) end, timeout: 200
  #   assert {:error, {:k, :already_exists}} == AgentMap.init mag, :k, fn -> :timer.sleep(300) end, timeout: 200
  #   assert {:ok, 42} == AgentMap.init mag, :k2, fn -> 42 end, late_call: false

  #   AgentMap.cast mag, :k2, & :timer.sleep(100) && &1 #blocks for 100 ms

  #   assert {:error, :timeout} == AgentMap.update mag, :k, fn _ -> 0 end, 50
  #   assert 42 == AgentMap.get mag, :k, & &1 #update was not happend
  # end
end

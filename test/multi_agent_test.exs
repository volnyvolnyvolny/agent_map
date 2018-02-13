defmodule MultiAgentTest do
  use ExUnit.Case
  doctest MultiAgent

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
    import MultiAgent
    mag = new uno: 22, dos: 24, tres: 42, cuatro: 44
    assert 22 == get_and_update mag, :uno, & {&1, &1 + 1}
    assert 23 == get mag, :uno, & &1

    assert 42 == get_and_update mag, :tres, fn _ -> :pop end
    assert nil == get mag, :tres, & &1

    #
    # transaction calls:
    #
    assert [23, 24] == get_and_update mag, fn [u, d] ->
      [{u, d}, {d, u}]
    end, [:uno, :dos]

    assert [24,23] == get mag, & &1, [:uno, :dos]

    assert [42] == get_and_update mag, fn _ -> :pop end, [:dos]

    assert [24, nil, nil, 44] == get mag, & &1, [:uno, :dos, :tres, :cuatro]

    assert [24, nil, :_, 44] == get_and_update mag, fn _ ->
      [:id, {nil, :_}, {:_, nil}, :pop]
    end, [:uno, :dos, :tres, :cuatro]

    [24, :_, nil, nil] == get mag, & &1, [:uno, :dos, :tres, :cuatro]
  end
end

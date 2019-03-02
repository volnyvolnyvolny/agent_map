defmodule AgentMapTest do
  use ExUnit.Case

  import :timer
  import AgentMap
  import AgentMap.Utils

  doctest AgentMap, import: true

  # test "…" do
  #   # am =
  #   #   AgentMap.new(a: 1, b: 2, c: 3)

  #   # assert am
  #   # |> sleep(:a, 100, !: :max)
  #   # |> put(:a, 42)
  #   # |> sleep(:b, 100, !: :max)
  #   # |> put(:b, 42)
  #   # |> take([:a, :b, :d]) == %{a: 1, b: 2}
  # end

  test "Memo example" do
    alias Test.{Memo, Calc}

    assert 0..10000
           |> Stream.map(&Calc.fib(&1))
           |> Enum.take(10000)
           |> Enum.find_index(&(&1 == 102_334_155)) == 40

    Memo.stop()
  end

  test "Account example" do
    alias Test.Account

    Account.start_link()

    #

    assert Account.balance(:Alice) == :error

    assert Account.deposit(:Alice, 10_000) == {:ok, 10_000}
    assert Account.deposit(:Alice, 10_000) == {:ok, 20_000}

    assert Account.withdraw(:Alice, 30) == {:ok, 19_970}

    assert Account.withdraw(:Alice, 20_000) == :error

    #
    assert Account.balance(:Alice) == {:ok, 19_970}
    assert Account.transfer(:Alice, :Bob, 30) == :error

    assert Account.open(:Bob) == :ok

    assert Account.transfer(:Alice, :Bob, 30) == :ok
    assert Account.balance(:Alice) == {:ok, 19_940}
    assert Account.balance(:Bob) == {:ok, 30}

    #

    Account.stop()
  end

  test "Collectable" do
    am = AgentMap.new()

    proc = fn c ->
      1..1000
      |> Enum.map(&{&1, 1 / &1})
      |> Enum.into(c)
    end

    map = proc.(%{})
    am = proc.(am)

    assert to_map(am) == map
  end

  test "delete/3" do
    assert AgentMap.new(a: 1)
           |> sleep(:a, 20)
           |> delete(:a, !: :min)
           |> put(:a, 2)
           |> get(:a) == nil

    assert AgentMap.new(a: 1, b: 2)
           |> sleep(:a, 20)
           |> delete(:a)
           |> to_map() == %{a: 1, b: 2}
  end

  test "keys/1" do
    assert %{a: 1, b: nil, c: 3}
           |> AgentMap.new()
           |> sleep(:d, 20)
           |> keys() == [:a, :b, :c, :d]
  end

  test "update/4" do
    %{pid: p} = am = AgentMap.new(a: 1)

    :sys.trace(p, true)

    assert am
           |> sleep(:a, 20)
           |> put(:a, 3)
           |> update(:a, fn 3 -> 4 end)
           |> update(:a, fn 1 -> 2 end, !: {:max, +1})
           |> get(:a) == 4
  end
end

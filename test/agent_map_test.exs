defmodule AgentMapTest do
  use ExUnit.Case

  import :timer
  import AgentMap
  import AgentMap.Utils

  doctest AgentMap, import: true

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
    import Test.Account

    Account.start_link()

    #

    assert balance(:Alice) == :error

    assert deposit(:Alice, 10_000) == {:ok, 10_000}
    assert deposit(:Alice, 10_000) == {:ok, 20_000}

    assert withdraw(:Alice, 30) == {:ok, 19_970}

    assert withdraw(:Alice, 20_000) == :error

    #
    assert balance(:Alice) == {:ok, 19_970}
    assert transfer(:Alice, :Bob, 30) == :error

    assert open(:Bob) == :ok

    assert transfer(:Alice, :Bob, 30) == :ok
    assert balance(:Alice) == {:ok, 19_940}
    assert balance(:Bob) == {:ok, 30}

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

  test "drop/3" do
    am =
      %{a: 1, b: 2, c: 3}
      |> AgentMap.new()
      |> drop([:b, :d])

    assert to_map(am) == %{a: 1, b: 2, c: 3}

    sleep(20)

    assert to_map(am) == %{a: 1, c: 3}
  end

  test "keys/1" do
    assert %{a: 1, b: nil, c: 3}
           |> AgentMap.new()
           |> sleep(:d, 20)
           |> keys() == [:a, :b, :c, :d]
  end

  test "update/4" do
    am = AgentMap.new(a: 1)

    assert am
           |> sleep(:a, 20)
           |> put(:a, 3)
           |> cast(:a, fn 3 -> 4 end)
           |> update(:a, fn 1 -> 2 end, !: {:max, +1})
           |> get(:a) == 4
  end
end

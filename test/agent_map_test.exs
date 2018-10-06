defmodule AgentMapTest do
  import AgentMap
  import :timer

  use ExUnit.Case
  doctest AgentMap

  test "delete" do
    am = AgentMap.new()

    next = fn
      nil ->
        sleep(10)
        [1]

      [v | _] = hist ->
        sleep(10)
        [v + 1 | hist]
    end

    assert am
           |> put(:a, [1])
           |> cast(:a, next)
           |> cast(:a, next)
           |> fetch(:a, !: false) == {:ok, [3, 2, 1]}

    # 1 → (sleep → 2) → (sleep → 3) → fetch
    #

    assert am
           |> put(:a, [1])
           |> cast(:a, next)
           |> cast(:a, next)
           |> delete(:a)
           |> fetch(:a, !: false) == :error

    # 1 → (sleep → 2) → (sleep → 3) → delete → fetch
    #

    assert am
           |> put(:a, [1])
           |> cast(:a, next)
           |> cast(:a, next)
           |> get(:pause, fn _ -> sleep(1) end)
           |> delete(:a, !: true)
           |> fetch(:a, !: false) == {:ok, [3, 2]}

    # 1 → delete → (sleep → 2) → (sleep → 3) → fetch
    #

    assert am
           |> put(:a, [1])
           |> cast(:a, next)
           |> cast(:a, next)
           |> delete(:a, cast: false)
           |> fetch(:a) == :error

    # 1 → (sleep → 2) → (sleep → 3) → delete → fetch
    #

    assert am
           |> put(:a, [1])
           |> cast(:a, next)
           |> cast(:a, next)
           |> get(:pause, fn _ -> sleep(1) end)
           |> delete(:a, !: true, cast: false)
           |> fetch(:a) == :error

    # 1 → delete → fetch → (sleep → 2) → (sleep → 3) …
    #

    assert fetch(am, :a, !: false) == {:ok, [3, 2]}
    # … → fetch
  end

  test "drop" do
    import AgentMap
    import :timer
    #
    assert %{a: 1, b: 2, c: 3}
           |> AgentMap.new()
           |> cast([:a, b], &(sleep(20) && &1))
           |> put(:a, "low", priority: :low)
           |> put(:a, "mid", priority: :mid)
           |> put(:a, "high", priority: :high)
           |> drop([:a], priority: :mid)
           |> take([:a, :b, :c]) == %{a: "low", c: 3}
  end

  test "put" do
    assert %{a: 0}
           |> AgentMap.new()
           |> AgentMap.cast(:a, &(:timer.sleep(20) && &1))
           |> AgentMap.put(:a, 1, priority: :low)
           |> AgentMap.put(:a, 2, priority: :mid)
           |> AgentMap.put(:a, 3, priority: :high)
           |> AgentMap.put(:b, 1, priority: :low)
           |> AgentMap.put(:b, 2, priority: :mid)
           |> AgentMap.put(:b, 3, priority: :high)
           |> AgentMap.take([:a, :b]) == %{a: 1, b: 3}
  end

  test "main" do
    import :timer
    import AgentMap

    am = AgentMap.new(a: 1, b: 2)

    assert am
           |> delete(:a)
           |> take([:a, :b]) == %{b: 2}

    f =
      &fn hist ->
        sleep(10)
        (hist && hist ++ [&1]) || [&1]
      end

    assert am
           |> cast(:a, f.(1))
           |> cast(:a, f.(2))
           |> cast(:a, f.(3))
           |> fetch(:a, !: false) == {:ok, [1, 2, 3]}

    assert am
           |> put(:a, [1])
           |> cast(:a, f.(2))
           |> cast(:a, f.(3))
           |> delete(:a)
           |> fetch(:a, !: false) == :error

    for _ <- 1..1000 do
      assert am
             |> put(:a, [1])
             |> cast(:a, f.(2))
             |> cast(:a, f.(3))
             |> delete(:a, !: true)
             |> fetch(:a, !: false) == {:ok, [2, 3]}
    end

    assert am
           |> put(:a, [1])
           |> cast(:a, f.(2))
           |> cast(:a, f.(3))
           |> delete(:a, cast: false)
           |> fetch(:a) == :error

    assert am
           |> put(:a, [1])
           |> cast(:a, f.(2))
           |> cast(:a, f.(3))
           |> delete(:a, !: true, cast: false)
           |> fetch(:a) == :error

    assert fetch(am, :a, !: false) == {:ok, [2, 3]}
  end

  test "info" do
    import AgentMap
    #
    am = AgentMap.new()

    assert info(am, :k)[:max_processes] == 5
    #
    for _ <- 1..100 do
      Task.async(fn ->
        get(am, :k, &(:timer.sleep(40) && &1), !: true)
      end)
    end

    sleep(10)

    assert IO.inspect(info(am, :k)[:processes]) > 5
  end

  test "update!" do
    import AgentMap
    import :timer
    #
    am = AgentMap.new(Alice: 1)

    assert am
           |> cast(:Alice, fn v ->
             IO.inspect({v, 2})
             sleep(100)
             2
           end)
           |> cast(:Alice, fn v ->
             IO.inspect({v, 4})
             4
           end)
           |> update!(:Alice, fn v ->
             IO.inspect({v, 5})
             5
           end)
           |> update!(
             :Alice,
             fn v ->
               IO.inspect({v, 3})
               3
             end,
             !: true
           )
           |> fetch(:Alice, !: false) == {:ok, 5}

    #
    # assert update!(am, :Bob, & &1)
    # ** (KeyError) key :Bob not found
  end
end

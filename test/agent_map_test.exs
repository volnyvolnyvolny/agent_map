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
end

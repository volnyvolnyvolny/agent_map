defmodule AgentMapMultiTest do
  alias AgentMap.{Multi, Server}

  import :timer
  import Server.State
  import AgentMap

  use ExUnit.Case

  test "Multi.get(…, …, …, !: true)" do
    fun = fn _ ->
      sleep(50)
      24
    end

    am =
      AgentMap.new(a: 42, b: 1, c: 4)
      |> cast(:a, fun)
      |> cast(:b, fun)

    assert Multi.get(am, [:a, :b, :c, :d], & &1, !: true) == [42, 1, 4, nil]
  end

  test "Multi.get(…, …, …, !: false)" do
    fun = fn _ ->
      sleep(50)
      24
    end

    am =
      AgentMap.new(a: 42, b: 1, c: 4)
      |> cast(:a, fun)
      |> cast(:b, fun)

    assert Multi.get(am, [:a, :b, :c, :d], & &1) == [42, 1, 4, nil]
  end

  test "Multi.get_and_update" do
    fun =
      &fn _ ->
        sleep(50)
        &1
      end

    am =
      AgentMap.new(a: 42, b: 1, c: 4)
      |> cast(:a, fun.(24))
      |> cast(:b, fun.(24))
      |> cast(:a, fun.(33))
      |> cast(:b, fun.(33))

    assert Multi.get(am, [:a, :b, :c, :d], & &1) == [42, 1, 4, nil]
    assert Multi.get_and_update(am, [:a, :b, :c, :d], &{&1}, !: true) == [24, 24, 4, nil]
    assert Multi.get_and_update(am, [:a, :b, :c, :d], &{&1}, !: true) == [24, 24, 4, nil]
    assert Multi.get_and_update(am, [:a, :b, :c, :d], &{&1}) == [33, 33, 4, nil]
  end
end

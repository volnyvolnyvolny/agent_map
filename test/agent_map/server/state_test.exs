defmodule AgentMapServerStateTest do
  alias AgentMap.Server.State
  import State

  use ExUnit.Case

  test "put" do
    map = &elem(&1, 0)

    assert map.(put({%{}, 5}, :k, box(42))) == %{k: box(42)}
    assert map.(put({%{}, 5}, :k, {box(42), 6})) == %{k: {box(42), 6}}

    assert map.(put({%{}, 5}, :k, {box(42), {4, 5}})) == %{k: {box(42), 4}}
    assert map.(put({%{}, 5}, :k, {box(42), {4, 7}})) == %{k: {box(42), {4, 7}}}

    assert map.(put({%{}, 5}, :k, {box(42), {0, 7}})) == %{k: {box(42), {0, 7}}}
    assert map.(put({%{}, 5}, :k, {box(42), {0, 5}})) == %{k: box(42)}

    # b = nil
    assert map.(put({%{k: box(42)}, 5}, :k, nil)) == %{}
    assert map.(put({%{k: box(42)}, 5}, :k, {nil, 6})) == %{k: {nil, 6}}
    assert map.(put({%{k: box(42)}, 5}, :k, {nil, 0})) == %{}

    assert map.(put({%{k: box(42)}, 5}, :k, {nil, {4, 5}})) == %{k: {nil, 4}}
    assert map.(put({%{k: box(42)}, 5}, :k, {nil, {4, 7}})) == %{k: {nil, {4, 7}}}

    assert map.(put({%{k: box(42)}, 5}, :k, {nil, {0, 7}})) == %{k: {nil, {0, 7}}}
    assert map.(put({%{k: box(42)}, 5}, :k, {nil, {0, 5}})) == %{}
  end

  test "get" do
    b = {:value, 42}

    assert get({%{}, 5}, :k) == {nil, {0, 5}}
    assert get({%{k: {nil, 0}}, 5}, :k) == {nil, {0, 5}}
    assert get({%{k: {b, {1, 4}}}, 5}, :y) == {nil, {0, 5}}
    assert get({%{k: {nil, 4}}, 5}, :k) == {nil, {4, 5}}
    assert get({%{k: {nil, {4, 6}}}, 5}, :k) == {nil, {4, 6}}

    assert get({%{k: b}, 5}, :k) == {b, {0, 5}}
    assert get({%{k: {b, 1}}, 5}, :k) == {b, {1, 5}}
    assert get({%{k: {b, {4, 6}}}, 5}, :k) == {b, {4, 6}}
  end

  test "fetch" do
    state =
      {%{}, 7}
      |> put(:a, box(42))
      |> put(:b, {box(1), 4})
      |> put(:c, {box(4), {1, 6}})
      |> put(:d, {nil, 5})

    assert state == {%{a: box(42), b: {box(1), 4}, c: {box(4), {1, 6}}, d: {nil, 5}}, 7}
    assert fetch(state, :a) == {:ok, 42}
    assert fetch(state, :b) == {:ok, 1}
    assert fetch(state, :c) == {:ok, 4}
    assert fetch(state, :d) == :error
    assert fetch(state, :e) == :error

    state =
      state
      |> spawn_worker(:c)
      |> spawn_worker(:d)
      |> spawn_worker(:e)

    assert fetch(state, :c) == {:ok, 4}
    assert fetch(state, :d) == :error
    assert fetch(state, :e) == :error
  end

  test "take" do
    state =
      {%{}, 7}
      |> put(:a, box(42))
      |> put(:b, {box(1), 4})
      |> put(:c, {box(4), {1, 6}})
      |> put(:d, {nil, 5})
      |> spawn_worker(:c)
      |> spawn_worker(:d)
      |> spawn_worker(:e)

    assert take(state, [:a, :b, :c, :d, :e]) == %{a: 42, b: 1, c: 4}
  end

  test "separate" do
    state =
      {%{}, 7}
      |> put(:a, box(42))
      |> put(:b, {box(1), 4})
      |> put(:c, {box(4), {1, 6}})
      |> put(:d, {nil, 5})
      |> spawn_worker(:c)
      |> spawn_worker(:d)
      |> spawn_worker(:e)

    {:pid, wc} = get(state, :c)
    {:pid, wd} = get(state, :d)
    {:pid, we} = get(state, :e)

    assert {%{a: 42, b: 1}, %{c: wc, d: wd, e: we}} == separate(state, [:a, :b, :c, :d, :e])
  end
end

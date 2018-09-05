defmodule AgentMapCommonTest do
  import AgentMap.Common
  alias AgentMap.Req
  import System, only: [system_time: 0]

  use ExUnit.Case

  test "put" do
    map = &elem(&1, 0)

    b = {:value, 42}
    assert(map.(put({%{}, 5}, :k, b)) == %{k: b})
    assert(map.(put({%{}, 5}, :k, {b, 6})) == %{k: {b, 6}})

    assert(map.(put({%{}, 5}, :k, {b, {4, 5}})) == %{k: {b, 4}})
    assert(map.(put({%{}, 5}, :k, {b, {4, 7}})) == %{k: {b, {4, 7}}})

    assert(map.(put({%{}, 5}, :k, {b, {0, 7}})) == %{k: {b, {0, 7}}})
    assert(map.(put({%{}, 5}, :k, {b, {0, 5}})) == %{k: b})

    #b = nil
    assert(map.(put({%{k: b}, 5}, :k, nil)) == %{})
    assert(map.(put({%{k: b}, 5}, :k, {nil, 6})) == %{k: {nil, 6}})

    assert(map.(put({%{k: b}, 5}, :k, {nil, {4, 5}})) == %{k: {nil, 4}})
    assert(map.(put({%{k: b}, 5}, :k, {nil, {4, 7}})) == %{k: {nil, {4, 7}}})

    assert(map.(put({%{k: b}, 5}, :k, {nil, {0, 7}})) == %{k: {nil, {0, 7}}})
    assert(map.(put({%{k: b}, 5}, :k, {nil, {0, 5}})) == %{})
  end

  test "get" do
    b = {:value, 42}

    assert(get({%{}, 5}, :k) == {nil, {0, 5}})
    assert(get({%{k: {nil, 0}}, 5}, :k) == {nil, {0, 5}})
    assert(get({%{k: {b, {1, 4}}}, 5}, :y) == {nil, {0, 5}})
    assert(get({%{k: {nil, 4}}, 5}, :k) == {nil, {4, 5}})
    assert(get({%{k: {nil, {4, 6}}}, 5}, :k) == {nil, {4, 6}})

    assert(get({%{k: b}, 5}, :k) == {b, {0, 5}})
    assert(get({%{k: {b, 1}}, 5}, :k) == {b, {1, 5}})
    assert(get({%{k: {b, {4, 6}}}, 5}, :k) == {b, {4, 6}})
  end

  test "run" do
    req =
      %Req{
        action: :_,
        inserted_at: system_time(),
        data: {:key, & &1 * 2},
        timeout: 100
      }

    assert(run(req, 21) == {:ok, 42})
  end
end

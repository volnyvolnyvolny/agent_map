defmodule AgentMapMultiRequestTest do
  alias AgentMap.{Multi.Req, Server}
  import :timer
  import Server.State

  use ExUnit.Case

  test "handle(%{action: :get, !: true})" do
    state =
      {%{}, 3}
      |> put(:a, box(42))
      |> put(:b, {box(1), 4})
      |> put(:c, {box(4), {1, 6}})
      |> put(:d, {nil, 5})
      |> spawn_worker(:a)
      |> spawn_worker(:b)
      |> spawn_worker(:c)
      |> spawn_worker(:d)

    {:pid, wa} = get(state, :a)
    {:pid, wb} = get(state, :b)

    r = %{
      action: :get_and_update,
      fun: fn _ ->
        sleep(50)
        {:_get, 24}
      end
    }

    send(wa, r)
    send(wb, r)

    r = %Req{action: :get, !: true, fun: & &1, keys: [:a, :b, :c, :d], from: {self(), :_ref}}
    Req.handle(r, state)

    assert_receive {:_ref, [42, 1, 4, nil]}

    #

    r = %Req{action: :get, !: false, fun: & &1, keys: [:a, :b, :c, :d], from: {self(), :_ref}}
    Req.handle(r, state)

    assert_receive {:_ref, [24, 24, 4, nil]}

    #

    r = %Req{
      action: :get_and_update,
      !: false,
      fun: fn _ -> :pop end,
      keys: [:a, :b, :c, :d],
      from: {self(), :_ref}
    }

    Req.handle(r, state)

    assert_receive {:_ref, [24, 24, 4, nil]}

    Req.handle(%{r | action: :get, fun: & &1}, state)

    assert_receive {:_ref, [nil, nil, nil, nil]}
  end
end

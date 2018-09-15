defmodule AgentMapTest do
  import AgentMap
  # import :timer

  use ExUnit.Case
  #  doctest AgentMap

  test "main" do
    import AgentMap
    am = AgentMap.new(a: 1, b: 2)

    assert am
           |> delete(:a)
           |> take([:a, :b]) == %{b: 2}

    #
    import :timer

           am
           |> cast(:b, fn 2 ->
             IO.inspect(:xui)
             sleep(10)
             IO.inspect(:xiu)
             42
           end)
           |> cast(:b, fn nil ->
             IO.inspect(:zho)
             sleep(10)
             24
           end)

    sleep(3)

    am
    |> delete(:b, cast: false)

    sleep(3)
    assert am |> fetch(:b) == {:ok, 2}

    # assert am
    #        |> delete(:b, !: true, cast: false)
    #        |> fetch(:b) == :error

    # assert fetch(am, :b, !: false) == 42

    # assert am
    #        |> cast(:b, fn 42 ->
    #          sleep(10)
    #          2
    #        end)
    #        |> delete(:b, cast: false)
    #        |> fetch(:b) == :error
  end
end

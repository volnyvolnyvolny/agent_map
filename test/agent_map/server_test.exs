defmodule AgentMapServerTest do
  alias AgentMap.Server
  import :timer

  use ExUnit.Case

  test "init" do
    args = [
      funs: [
        a: 42,
        b: fn -> sleep(50) end,
        c: fn -> sleep(:infinity) end,
        d: fn -> 42 end
      ],
      timeout: 40,
      max_p: {10, :infinity}
    ]

    assert Server.init(args) == {:stop, [a: :badfun, b: :timeout, c: :timeout]}

    #

    args = [
      funs: [
        a: fn -> 42 end,
        b: :notfun,
        c: fn -> raise KeyError end,
        d: 42,
        e: & &1
      ],
      timeout: 5000,
      max_p: {10, :infinity}
    ]

    assert {:stop,
            [
              b: :badfun,
              c: {%KeyError{key: nil, message: nil, term: nil}, _stacktrace},
              d: :badfun,
              e: :badarity
            ]} = Server.init(args)

    #

    args = [
      funs: [
        a: fn -> 42 end,
        b: fn ->
          sleep(30)
          42
        end
      ],
      timeout: 40,
      max_p: {10, :infinity}
    ]

    assert Server.init(args) == {:ok, {%{a: 42, b: 42}, %{}}}
    assert Process.get(:max_p) == {10, :infinity}
  end
end

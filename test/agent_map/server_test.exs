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
      max_processes: 10
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
      max_processes: 10
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
      max_processes: 10
    ]

    assert Server.init(args) == {:ok, {%{a: {:value, 42}, b: {:value, 42}}, 10}}
  end
end

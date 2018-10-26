defmodule AgentMapRequestTest do
  alias AgentMap.Req
  import Req

  use ExUnit.Case

  test "compress" do
    f = & &1

    req = %Req{act: :max_processes, key: :a, data: 6}
    assert compress(req) == %{act: :max_processes, data: 6, !: 256}

    req = %Req{act: :get, key: :a, fun: f, data: nil}
    assert compress(req) == %{act: :get, fun: f, !: 256}

    req = %Req{
      act: :get,
      key: :a,
      fun: f,
      data: nil
    }

    assert compress(req) == %{
             act: :get,
             fun: f,
             !: 256
           }
  end
end

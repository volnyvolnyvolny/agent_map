defmodule AgentMapCommonTest do
  import AgentMap.Common
  alias AgentMap.Req
  import System, only: [system_time: 0]

  use ExUnit.Case

  test "run" do
    # req =
    #   %Req{
    #     action: :_,
    #     inserted_at: system_time(),
    #     data: {:key, & &1 * 2},
    #     timeout: 100
    #   }

    # assert(run(req, 21) == {:ok, 42})
  end
end

defmodule AgenxtMapWorkerTest do
  alias AgentMap.{Worker, Server.State, Time}
  import State
  import Time

  use ExUnit.Case

  import ExUnit.CaptureLog
  import :timer

  defp ms(), do: 1_000_000

  def a <~> b, do: (a - b) in -1..1

  test "spawn_get_task" do
    fun = fn value ->
      sleep(10)
      key = Process.get(:key)
      box = Process.get(:value)

      {value, {key, box}}
    end

    msg = %{action: :get, from: {self(), :_}, fun: fun}

    b = box(42)
    Worker.spawn_get_task(msg, {:key, b})
    assert_receive {:_, {42, {:key, ^b}}}
    assert_receive %{info: :done, key: :key}

    # fresh

    msg =
      msg
      |> Map.put(:timeout, {:!, 5})
      |> Map.put(:inserted_at, now() - 3 * ms())

    Worker.spawn_get_task(msg, {:key, nil})
    assert_receive {:_, {nil, {:key, nil}}}
    assert_receive %{info: :done, key: :key}

    # expired
    msg =
      msg
      |> Map.put(:timeout, {:!, 5})
      |> Map.put(:inserted_at, now() - 7 * ms())

    assert capture_log(fn ->
             Worker.spawn_get_task(msg, {:key, b})
             refute_receive {:_, {42, {:key, ^b}}}
             assert_receive %{info: :done, key: :key}
           end) =~ "Call is expired and will not be executed."
  end
end

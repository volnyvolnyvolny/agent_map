defmodule AgentMapWorkerTest do
  alias AgentMap.{Req, Worker, Server.State, Common}
  import State
  import Common

  use ExUnit.Case

  import ExUnit.CaptureLog

  defp ms(), do: 1_000_000

  test "spawn_get_task" do
    fun = fn value ->
      key = Process.get(:"$key")
      box = Process.get(:"$value")

      {value, {key, box}}
    end

    req = %Req{action: :get, from: f = {self(), :_}, data: {:_, fun}}

    msg = Req.compress(req)
    Worker.spawn_get_task(msg, {:key, box(42)})
    assert_receive {:_, {42, {:key, {:value, 42}}}}
    assert_receive %{info: :done, key: :key}

    # fresh

    msg =
      msg
      |> Map.put(:timeout, {:drop, 5})
      |> Map.put(:inserted_at, now() - 3 * ms())

    Worker.spawn_get_task(msg, {:key, nil})
    assert_receive {:_, {nil, {:key, nil}}}
    assert_receive %{info: :done, key: :key}

    msg =
      msg
      |> Map.put(:timeout, {:break, 5})
      |> Map.put(:inserted_at, now() - 3 * ms())

    Worker.spawn_get_task(msg, {:key, box(42)})
    assert_receive {:_, {42, {:key, {:value, 42}}}}
    assert_receive %{info: :done, key: :key}

    # expired
    msg =
      msg
      |> Map.put(:timeout, {:drop, 5})
      |> Map.put(:inserted_at, now() - 7 * ms())

    Worker.spawn_get_task(msg, {:key, box(42)})

    assert capture_log(fn ->
             refute_receive {:_, {42, {:key, {:value, 42}}}}
             assert_receive %{info: :done, key: :key}
           end) =~ "Key :key call is expired and will not be executed."

    msg =
      msg
      |> Map.put(:timeout, {:break, 5})
      |> Map.put(:inserted_at, now() - 7 * ms())

    Worker.spawn_get_task(msg, {:key, box(42)})

    assert capture_log(fn ->
             refute_receive {:_, {42, {:key, {:value, 42}}}}
             assert_receive %{info: :done, key: :key}
           end) =~ "Key :key call takes too long and will be terminated."
  end

  test "handle(%{action: get}" do
    # state =
    #   {%{}, 7}
    #   |> put(:a, box(42))
    #   |> put(:b, {box(1), 4})
    #   |> put(:c, {box(4), {1, 6}})
    #   |> put(:d, {nil, 5})
    #   |> spawn_worker(:b)
    #   |> spawn_worker(:c)

    # assert false
  end

  test "handle(%{action: :max_processes}" do
    state =
      {%{}, 7}
      |> put(:a, box(42))
      |> spawn_worker(:a)

    {:pid, w} = get(state, :a)
    assert Worker.dict(w)[:"$processes"] == 1
    assert Worker.dict(w)[:"$max_processes"] == 5

    r = %Req{action: :max_processes, data: {:a, 1}, from: {self(), :_}}
    send(w, Req.to_msg(r))

    assert Worker.dict(w)[:"$max_processes"] == 1
  end

  # test "get" do
  #   assert false
  # end

  # test "selective receive" do
  #   assert false
  # end

  # test ":get!" do
  #   assert false
  # end

  # test ":done" do
  #   assert false
  # end
end

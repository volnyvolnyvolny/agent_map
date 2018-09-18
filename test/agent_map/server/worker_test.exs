defmodule AgenxtMapWorkerTest do
  alias AgentMap.{Req, Worker, Server.State, Common}
  import State
  import Common

  use ExUnit.Case

  import ExUnit.CaptureLog
  import :timer

  defp ms(), do: 1_000_000

  def a <~> b, do: (a - b) in -1..1

  test "spawn_get_task" do
    fun = fn value ->
      sleep(10)
      key = Process.get(:"$key")
      box = Process.get(:"$value")

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
      |> Map.put(:timeout, {:drop, 5})
      |> Map.put(:inserted_at, now() - 3 * ms())

    Worker.spawn_get_task(msg, {:key, nil})
    assert_receive {:_, {nil, {:key, nil}}}
    assert_receive %{info: :done, key: :key}

    msg =
      msg
      |> Map.put(:timeout, {:break, 15})
      |> Map.put(:inserted_at, now() - 3 * ms())

    Worker.spawn_get_task(msg, {:key, b})
    assert_receive {:_, {42, {:key, ^b}}}
    assert_receive %{info: :done, key: :key}

    # expired
    msg =
      msg
      |> Map.put(:timeout, {:drop, 5})
      |> Map.put(:inserted_at, now() - 7 * ms())

    assert capture_log(fn ->
             Worker.spawn_get_task(msg, {:key, b})
             refute_receive {:_, {42, {:key, ^b}}}
             assert_receive %{info: :done, key: :key}
           end) =~ "Key :key call is expired and will not be executed."

    msg =
      msg
      |> Map.put(:timeout, {:break, 5})
      |> Map.put(:inserted_at, now() - 7 * ms())

    assert capture_log(fn ->
             Worker.spawn_get_task(msg, {:key, b})
             refute_receive {:_, {42, {:key, ^b}}}
             assert_receive %{info: :done, key: :key}
           end) =~ "Key :key call is expired and will not be executed."

    msg =
      msg
      |> Map.put(:timeout, {:break, 5})
      |> Map.put(:inserted_at, now() - 4 * ms())

    assert capture_log(fn ->
             Worker.spawn_get_task(msg, {:key, box(42)})
             refute_receive {:_, {42, {:key, ^b}}}
             assert_receive %{info: :done, key: :key}
           end) =~ "Key :key call takes too long and will be terminated."
  end

  test "handle(%{action: :get}" do
    # state =
    #   {%{}, 7}
    #   |> put(:a, box(42))
    #   |> put(:b, {box(1), 4})
    #   |> put(:c, {box(4), {1, 6}})
    #   |> put(:d, {nil, 5})
    #   |> spawn_worker(:a)
    #   |> spawn_worker(:b)
    #   |> spawn_worker(:c)
    #   |> spawn_worker(:d)

    # {:pid, wa} = get(state, :a)
    # {:pid, wb} = get(state, :b)
    # {:pid, wc} = get(state, :c)
    # {:pid, wd} = get(state, :d)

    # r = %{action: :get, from: {self(), :_ref}, fun: &{Process.get(:"$key"), &1}}
    # send(wa, r)
    # send(wb, r)
    # send(wc, r)
    # send(wd, r)

    # assert_receive {:_ref, {:a, 42}}
    # assert_receive {:_ref, {:b, 1}}
    # assert_receive {:_ref, {:c, 4}}
    # assert_receive {:_ref, {:d, nil}}

    # r = %Req{action: :max_processes, key: :a, data: 3, from: {self(), :_ref}}
    # send(wa, Req.compress(r))
    # assert_receive {:_ref, 7}
    # assert Worker.dict(wa)[:"$max_processes"] == 3
    # assert Worker.dict(wa)[:"$processes"] == 1

    # req =
    #   &%{
    #     action: :get,
    #     from: {self(), :_ref},
    #     fun: fn _ ->
    #       sleep(10)
    #       &1
    #     end
    #   }

    # past = now()

    # send(wa, req.(1))
    # send(wa, req.(2))
    # send(wa, req.(3))

    # assert_receive {:_ref, 1}
    # t1 = to_ms(now() - past)
    # assert_receive {:_ref, 2}
    # t2 = to_ms(now() - past)
    # assert_receive {:_ref, 3}
    # t3 = to_ms(now() - past)

    # assert t1 <~> t2
    # assert t2 <~> t3

    # sleep(1)
    # past = now()

    # send(wa, req.(1))
    # send(wa, req.(2))
    # send(wa, req.(3))
    # send(wa, req.(4))

    # assert_receive {:_ref, 1}
    # t1 = to_ms(now() - past)
    # assert_receive {:_ref, 2}
    # t2 = to_ms(now() - past)
    # assert_receive {:_ref, 3}
    # t3 = to_ms(now() - past)
    # assert_receive {:_ref, 4}
    # t4 = to_ms(now() - past)

    # assert(t1 <~> t2)
    # assert(t2 <~> t3)
    # assert(t3 < t4)
  end

  test "handle(%{action: :get_and_update}" do
    # state =
    #   {%{}, 3}
    #   |> put(:a, box(42))
    #   |> put(:b, {box(1), 4})
    #   |> put(:c, {box(4), {1, 6}})
    #   |> put(:d, {nil, 5})
    #   |> spawn_worker(:a)
    #   |> spawn_worker(:b)
    #   |> spawn_worker(:c)
    #   |> spawn_worker(:d)

    # {:pid, wa} = get(state, :a)
    # {:pid, wb} = get(state, :b)
    # {:pid, wc} = get(state, :c)
    # {:pid, wd} = get(state, :d)

    # r = %Req{action: :get_and_update, from: {self(), :_ref}}
    # send(wa, Req.compress(%{r | fun: fn _ -> {Process.get(:"$key")} end}))
    # send(wb, Req.compress(%{r | fun: fn _ -> {Process.get(:"$key"), 0} end}))
    # send(wc, Req.compress(%{r | fun: fn _ -> :pop end}))
    # send(wd, Req.compress(%{r | fun: fn _ -> :id end}))

    # assert_receive {:_ref, :a}
    # assert_receive {:_ref, :b}
    # assert_receive {:_ref, 4}
    # assert_receive {:_ref, nil}

    # f = fn v ->
    #   sleep(10)
    #   {v, v + 1}
    # end

    # r_get = %Req{action: :get, from: {self(), :_ref}, fun: f}
    # r = %{r_get | action: :get_and_update}

    # sleep(5)
    # assert Worker.dict(wa)[:"$processes"] == 1
    # past = now()
    # send(wa, Req.compress(r_get))
    # send(wa, Req.compress(r_get))
    # send(wa, Req.compress(r))
    # send(wa, Req.compress(r_get))
    # send(wa, Req.compress(r_get))
    # send(wa, Req.compress(r_get))

    # assert_receive {:_ref, {42, 43}}
    # t1 = to_ms(now() - past)
    # assert_receive {:_ref, {42, 43}}
    # t2 = to_ms(now() - past)
    # assert_receive {:_ref, 42}
    # t3 = to_ms(now() - past)

    # # %{info: :done} * 2 messages just sent →
    # assert_receive {:_ref, {43, 44}}
    # t4 = to_ms(now() - past)

    # # →
    # assert_receive {:_ref, {43, 44}}
    # t5 = to_ms(now() - past)
    # assert_receive {:_ref, {43, 44}}
    # t6 = to_ms(now() - past)

    # assert t1 <~> t2
    # assert t2 <~> t3

    # assert t3 < t4
    # assert t4 < t5
    # assert t5 <~> t6

    # sleep(5)
    # assert Worker.dict(wa)[:"$processes"] == 1

    # send(wa, Req.compress(r_get))
    # send(wa, Req.compress(r_get))
    # send(wa, Req.compress(r_get))
    # send(wa, Req.compress(r_get))

    # sleep(5)
    # send(wa, Req.compress(%{r | !: true}))

    # assert_receive {:_ref, {43, 44}}
    # assert_receive {:_ref, {43, 44}}
    # assert_receive {:_ref, {43, 44}}
    # assert_receive {:_ref, 43}
    # assert_receive {:_ref, {44, 45}}, 200
  end
end

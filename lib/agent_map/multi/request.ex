defmodule AgentMap.Multi.Req do
  @moduledoc false

  alias AgentMap.{Common, CallbackError, Server, Worker, Multi.Req}

  import Worker, only: [broadcast: 2, collect: 2]
  import Common, only: [run: 3, reply: 2]
  import Server.State

  @enforce_keys [:action]

  defstruct [
    :action,
    :data,
    :from,
    :keys,
    :fun,
    :inserted_at,
    timeout: 5000,
    !: 256
  ]

  def timeout(req), do: AgentMap.Req.timeout(req)

  #
  defp prepair_workers(req, pids) do
    act = req.action
    me = self()

    f = fn _ ->
      if act == :get_and_update do
        Worker.share_value(to: me)
        Worker.accept_value()
      else
        Worker.share_value(to: me)
      end
    end

    req = %{action: :get_and_update, fun: f, !: req.!}
    broadcast(pids, req)
  end

  # on server
  defp prepair(%Req{action: :get, !: :now} = req, state) do
    map = take(state, req.keys)
    {state, {map, %{}}}
  end

  defp prepair(%Req{action: :get} = req, state) do
    {state, separate(state, req.keys)}
  end

  # action: :get_and_update
  defp prepair(req, state) do
    state =
      Enum.reduce(req.keys, state, fn key, state ->
        spawn_worker(state, key)
      end)

    {state, separate(state, req.keys)}
  end

  ##
  ##
  ##

  defp interpret(:get, _values, result) do
    {:ok, {result, :_id}}
  end

  defp interpret(_action, values, result) do
    n = length(values)

    case result do
      :pop ->
        {:ok, {values, List.duplicate(:drop, n)}}

      :id ->
        {:ok, {values, List.duplicate(:id, n)}}

      {get, :id} ->
        {:ok, {get, List.duplicate(:id, n)}}

      {get, :drop} ->
        {:ok, {get, List.duplicate(:drop, n)}}

      {get, values} when length(values) == n ->
        {:ok, {get, Enum.map(values, &box/1)}}

      {get} ->
        {:ok, {get, List.duplicate(:id, n)}}

      lst when is_list(lst) and length(lst) == n ->
        results =
          for {old_v, v} <- Enum.zip(values, lst) do
            case v do
              {g, v} ->
                {:ok, {g, box(v)}}

              {g} ->
                {:ok, {g, :id}}

              :id ->
                {:ok, {old_v, :id}}

              :pop ->
                {:ok, {old_v, :drop}}

              _err ->
                :error
            end
          end

        if :error in results do
          {:error, {:callback, result}}
        else
          {_ok, get_msgs} = Enum.unzip(results)
          {:ok, Enum.unzip(get_msgs) |> IO.inspect()}
        end

      {_, values} ->
        {:error, {:update, values}}

      _err ->
        {:error, {:callback, result}}
    end
  end

  #

  defp to_map(values) do
    for {pid, {:value, v}} <- values, into: %{} do
      {Worker.dict(pid)[:key], v}
    end
  end

  ##
  ##
  ##

  @doc false
  def handle(req, state) do
    {state, {map, workers}} = prepair(req, state)

    pids = Map.values(workers)

    # Worker may die before Task starts.
    server = self()
    ref = make_ref()

    Task.start_link(fn ->
      with prepair_workers(req, pids),
           send(server, {ref, :go!}),
           #
           {:ok, values} <- collect(pids, timeout(req)),
           #
           map = Map.merge(map, to_map(values)),
           #
           Process.put(:map, map),
           Process.put(:keys, req.keys),
           #
           values = Enum.map(req.keys, &map[&1]),
           #
           {:ok, result} <- run(req.fun, [values], timeout(req)),
           {:ok, {get, msgs}} <- interpret(req.action, values, result) |> IO.inspect() do
        #

        unless req.action == :get do
          for {key, msg} <- Enum.zip(req.keys, msgs) do
            send(workers[key], msg)
          end
        end

        reply(req.from, get)
      else
        {:error, {:callback, result}} ->
          raise CallbackError, got: result, multi_key?: true

        {:error, {:update, values}} ->
          raise CallbackError, len: length(values)

        err ->
          require Logger

          if req.action == :get_and_update do
            broadcast(pids, :id)
          end

          ks = inspect(req.keys)
          r = inspect(req)

          case err do
            {:error, :expired} ->
              Logger.error("Takes too long to collect values for the keys #{ks}. Req: #{r}.")

            {:error, :toolong} ->
              Logger.error(
                "Call (keys: #{ks}) takes too long to execute. It will be terminated. Req: #{r}."
              )
          end
      end
    end)

    receive do
      {^ref, :go!} ->
        {:noreply, state}
    end
  end
end

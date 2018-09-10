defmodule AgentMap.Multi.Req do
  @moduledoc false

  alias AgentMap.{Common, CallbackError, Server, Worker, Multi.Req}

  import Common, only: [run: 4, now: 0, left: 2, reply: 2]
  import Server.State

  @enforce_keys [:action]

  defstruct [
    :action,
    :data,
    :keys,
    :fun,
    :inserted_at,
    timeout: 5000,
    !: false
  ]

  def timeout(req), do: AgentMap.Req.timeout(req)

  defp broadcast(workers, msg) do
    for w <- workers, do: send(w, msg)
  end

  # On server
  def prepair(%Req{action: :get, !: true} = req, state) do
    {state, {take(state, req.keys), %{}}}
  end

  def prepair(%Req{keys: keys}, state) do
    Enum.reduce(keys, state, fn key, state ->
      spawn_worker(state, key)
    end)

    split = {_map, workers} = separate(state, keys)

    pids = Map.values(workers)
    broadcast(pids, :dontdie!)

    {state, split}
  end

  # On transaction process
  def prepair(req, pids) do
    me = self()
    act = req.action

    f = fn _ ->
      Worker.share_value(to: me)
      if act == :get_and_update do
        Worker.accept_value()
      end
    end

    req = %{action: req.action, fun: f, timeout: :infinity}
    broadcast(pids, req)
  end

  ##
  ##
  ##

  defp collect(map, [], _), do: {:ok, map}

  defp collect(_, _, t) when t < 0, do: {:error, :expired}

  defp collect(map, unknown, timeout) do
    past = now()

    receive do
      {key, nil} ->
        collect(map, unknown -- [key], left(timeout, since: past))

      {key, {:value, v}} ->
        map = Map.put(map, key, v)
        collect(map, unknown -- [key], left(timeout, since: past))
    after
      timeout ->
        {:error, :expired}
    end
  end

  ##
  ##
  ##

  defp interpret(values, result) do
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
        get_msgs =
          for {old_v, v} <- Enum.zip(values, lst) do
            case v do
              {g, v} ->
                {g, box(v)}

              {g} ->
                {g, :id}

              :id ->
                {old_v, :id}

              :pop ->
                {old_v, :drop}
            end
          end

        {:ok, Enum.unzip(get_msgs)}

      {_, values} ->
        {:error, {:update, values}}

      _err ->
        {:error, {:callback, result}}
    end
  end

  ##
  ##
  ##

  @doc false
  def handle(req, state) do
    {state, {map, workers}} = prepair(req, state)

    Task.start_link(fn ->
      pids = Map.values(workers)
      break? = match?({:break, _}, req.timeout)

      with prepair(req, pids),
           {:ok, map} <- collect(map, Map.keys(workers), timeout(req)),
           Process.put(:"$map", map),
           Process.put(:"$keys", req.keys),
           values = Enum.map(req.keys, &map[&1]),
           {:ok, result} <- run(req.fun, [values], timeout(req), break?),
           {:ok, {get, msgs}} <- interpret(values, result) do

        unless req.action == :get do
          for {key, msg} <- Enum.zip(req.keys, msgs) do
            send(workers[key], msg)
          end
        end

        reply(req.from, get)
      else
        {:error, {:callback, result}} ->
          raise CallbackError, got: result

        {:error, {:update, values}} ->
          raise CallbackError, len: length(values)

        err ->
          handle_error(err, req, pids)
      end
    end)

    {:noreply, state}
  end

  defp handle_error(err, req, pids) do
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
        Logger.error("Keys #{ks} transaction call takes too long and will be terminated. Req: #{r}.")
    end
  end
end

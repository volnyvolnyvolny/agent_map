defmodule AgentMap.Multi.Req do
  @moduledoc false

  alias AgentMap.{CallbackError, Server, Worker, Req}

  import Worker, only: [broadcast: 2, collect: 2]
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

  #
  defdelegate timeout(req), to: Req

  defdelegate compress(req), to: Req

  defdelegate get_and_update(req, fun), to: Req

  #
  defp run(req, values) do
    if timeout(req) > 0 do
      {:ok, apply(req.fun, [values])}
    else
      {:error, :expired}
    end
  end

  #
  defp to_req(m_req) do
    struct(Req, Map.from_struct(m_req))
  end

  #
  defp fun_for(:get_and_update, me) do
    fn _ ->
      Worker.share_value(to: me)
      Worker.accept_value()
    end
  end

  defp fun_for(:get, me) do
    fn _ ->
      Worker.share_value(to: me)
    end
  end

  #

  defp prepair_workers(req, pids) do
    fun = fun_for(req.action, self())
    req = get_and_update(%{req | from: nil}, fun)
    broadcast(pids, compress(req))
  end

  # on server
  defp prepair(%{action: :get, !: :now} = req, state) do
    map = take(state, req.keys)
    {state, {map, %{}}}
  end

  defp prepair(%{action: :get} = req, state) do
    {state, separate(state, req.keys)}
  end

  # action: :get_and_update
  defp prepair(req, state) do
    state = Enum.reduce(req.keys, state, &spawn_worker(&2, &1))

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
          {:ok, Enum.unzip(get_msgs)}
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

  def handle(%{action: :drop, from: nil} = req, state) do
    keys = req.keys

    req = %{to_req(req) | action: :delete}

    state =
      Enum.reduce(keys, state, fn key, state ->
        case Req.handle(%{req | key: key}, state) do
          {:noreply, state} ->
            state

          {:reply, :_done, state} ->
            state
        end
      end)

    {:noreply, state}
  end

  def handle(%{action: :drop} = req, state) do
    req
    |> get_and_update(fn _ -> :pop end)
    |> handle(state)
  end

  #

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
           values = Enum.map(req.keys, &Map.get(map, &1, req.data)),
           #
           {:ok, result} <- run(req, values),
           {:ok, {get, msgs}} <- interpret(req.action, values, result) do
        #

        unless req.action == :get do
          for {key, msg} <- Enum.zip(req.keys, msgs) do
            send(workers[key], msg)
          end
        end

        if req.from do
          GenServer.reply(req.from, get)
        end
      else
        {:error, {:callback, result}} ->
          raise CallbackError, got: result, multi_key?: true

        {:error, {:update, values}} ->
          raise CallbackError, len: length(values)

        {:error, :expired} ->
          require Logger

          if req.action == :get_and_update do
            broadcast(pids, :id)
          end

          ks = inspect(req.keys)
          r = inspect(req)

          Logger.error("Takes too long to collect values for the keys #{ks}. Req: #{r}.")
      end
    end)

    receive do
      {^ref, :go!} ->
        {:noreply, state}
    end
  end
end

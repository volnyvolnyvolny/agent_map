defmodule AgentMap.Multi.Req do
  @moduledoc false

  alias AgentMap.{CallbackError, Server, Worker, Req}

  import Server.State

  @enforce_keys [:act]

  defstruct [
    :act,
    :data,
    :from,
    :keys,
    :fun,
    !: 256
  ]

  #
  defdelegate compress(req), to: Req

  defdelegate get_and_update(req, fun), to: Req

  #
  defp to_req(m_req) do
    struct(Req, Map.from_struct(m_req))
  end

  #

  def collect(keys), do: collect(%{}, keys)

  def collect(values, []), do: values

  def collect(values, keys) do
    receive do
      {key, {:value, v}} ->
        keys = List.delete(keys, key)
        values
        |> Map.put(key, v)
        |> collect(keys)

      {key, nil} ->
        keys = List.delete(keys, key)
        collect(values, keys)
    end
  end

  #

  defp prepair_workers(req, pids) do
    me = self()

    fun = fn _ ->
      Worker.share_value(to: me)

      if req.act == :get_and_update do
        Worker.accept_value()
      end
    end

    req = %{req | from: nil, fun: fun}

    for w <- pids, do: send(w, compress(req))
  end

  # on server
  defp prepair(%{act: :get, !: :now} = req, state) do
    map = take(state, req.keys)
    {state, {map, %{}}}
  end

  defp prepair(%{act: :get} = req, state) do
    {state, separate(state, req.keys)}
  end

  # act: :get_and_update
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

  ##
  ##
  ##

  def handle(%{act: :drop, from: nil} = req, state) do
    keys = req.keys

    req = %{to_req(req) | act: :delete}

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

  def handle(%{act: :drop} = req, state) do
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
      send(server, {ref, :go!})
      #
      prepair_workers(req, pids)
      #
      keys = req.keys
      values = collect(Map.keys(workers))
      map = Map.merge(map, values)
      #
      Process.put(:map, map)
      Process.put(:keys, keys)
      #
      values = Enum.map(keys, &Map.get(map, &1, req.data))
      result = apply(req.fun, [values])

      case interpret(req.act, values, result) do
        {:ok, {get, msgs}} ->
          unless req.act == :get do
            for {key, msg} <- Enum.zip(keys, msgs) do
              send(workers[key], msg)
            end
          end

          if req.from do
            GenServer.reply(req.from, get)
          end

        {:error, {:callback, result}} ->
          raise CallbackError, got: result, multi_key?: true

        {:error, {:update, values}} ->
          raise CallbackError, len: length(values)
      end
    end)

    receive do
      {^ref, :go!} ->
        {:noreply, state}
    end
  end
end

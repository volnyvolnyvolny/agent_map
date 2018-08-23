defmodule AgentMap.Transaction do
  @moduledoc false

  alias AgentMap.{Common, Req, Worker}

  import Map, only: [keys: 1]
  import Worker, only: [unbox: 1]
  import Common, only: [dict: 1, run: 2, to_ms: 1]
  import Req, only: [get_value: 2]
  import System, only: [system_time: 0]

  require Logger

  ##
  ## HELPERS
  ##

  defp broadcast(keys, msg, state) when msg in [:id, :drop] do
    for key <- keys do
      case unpack(key, state) do
        {:pid, worker} ->
          d = dict(worker)
          send(worker, msg)
          unbox(d[:"$value"])

        {value, _} ->
          unbox(value)
      end
    end
  end

  defp broadcast(keys, values, state) do
    for {key, value} <- Enum.zip(keys, values) do
      {:pid, worker} = unpack(key, state)
      send(worker, {:value, value})
      value
    end
  end

  defp share(to: t) do
    k = Process.get(:"$key")
    v = Process.get(:"$value")
    send(t, {k, v})
  end

  defp accept() do
    receive do
      :drop ->
        :pop

      :id ->
        :id

      {:value, v} ->
        {:_, v}
    end
  end

  ##
  ## STAGES: prepair → collect → run → finalize
  ##

  defp worker?(key, state) do
    match?({:pid, _}, extract(key, state))
  end

  defp prepair(%{action: :get, !: true}, state) do
    # do nothing
    state
  end

  defp prepair(%{action: :get} = req, state) do
    {_, keys} = req.data

    s = self()

    fun = fn _ ->
      share(to: s)
    end

    for key <- keys, worker?(key, state) do
      req =
        %Req{
          action: :get_and_update,
          data: {key, fun},
          !: req.!,
          timeout: :infinity
        }

      Req.handle(req, state)
    end

    state
  end

  defp prepair(%{action: :get_and_update} = req, state) do
    {_, keys} = req.data

    s = self()

    fun = fn _ ->
      share(to: s)
      accept()
    end

    Enum.reduce(keys, state, fn key, state ->
      req =
        %Req{
          action: :get_and_update,
          data: {key, fun},
          !: req.!,
          timeout: :infinity
        }

      Req.handle(req, state)
    end)
  end

  defp collect(%{action: :get, !: true} = req, state) do
    {_, keys} = req.data

    for key <- keys do
      {key, get_value(key, state)}
    end
  end

  defp collect(req, state) do
    {_, keys} = req.data

    known =
      for key <- keys, not worker?(key, state) do
        {key, get_value(key, state)}
      end

    passed = to_ms(system_time() - req.inserted_at)
    timeout =
      case req.timeout do
        {_, timeout} ->
          timeout

        timeout ->
          timeout
      end

    if unbox_(req.timeout) > passed do
      _collect(known, keys -- Maps.keys(known), timeout - passed)
    else
      {:error, :expired}
    end
  end

  defp _collect(known, [], _), do: {:ok, known}

  defp _collect(known, unknown, timeout) do
    now = system_time()

    receive do
      {worker, value} ->
        key = dict(worker)[:"$key"]
        passed = to_ms(system_time() - now)

        case value do
          {:value, v} ->
            _collect(%{known | key => v}, unknown -- [key], timeout - passed)

          nil ->
            _collect(known, unknown -- [key], timeout - passed)
        end
    after
      timeout ->
        {:error, :expired}
    end
  end

  defp finalize(%{action: :get}, result, _state) do
    {:ok, result}
  end

  defp finalize(%{action: :get_and_update} = req, result, state) do
    {_, keys} = req

    case result do
      :pop ->
        {:ok, {:get, broadcast(keys, :drop, state)}}

      :id ->
        {:ok, {:get, broadcast(keys, :id, state)}}

      {get, :id} ->
        broadcast(keys, :id, state)
        {:ok, {:get, get}}

      {get, :drop} ->
        broadcast(keys, :drop, state)
        {:ok, {:get, get}}

      {get, values} when length(values) == length(keys) ->
        broadcast(keys, values, state)
        {:ok, {:get, get}}

      {_, _} ->
        {:error, :update}

      {get} ->
        broadcast(keys, :id, state)
        {:ok, {:get, get}}

      lst when is_list(lst) and length(lst) == length(keys) ->
        reply = fn key, msg, state ->
          {:pid, worker} = unpack(key, state)
          d = dict(worker)
          send(worker, msg)
          unbox(d[:"$value"])
        end

        get =
          for {key, ret} <- Enum.zip(keys, lst) do
            case ret do
              {get, v} ->
                reply.(key, {:value, v}, state)
                get

              {get} ->
                reply.(key, :id, state)
                get

              :id ->
                reply.(key, :id, state)

              :pop ->
                reply.(key, :drop, state)
            end
          end

        {:ok, {:get, get}}

      {:chain, {_kf, _fks} = d, values} when length(values) == length(keys) ->
        broadcast(keys, values, state)

        send(get(:"$gen_server"), %{req | data: d, action: :chain})
        {:ok, nil}

      {:chain, _, _} ->
        {:error, :update}

      err ->
        {:error, :callback}
    end
  end

  ##
  ## SINGLE KEY GET REQUEST
  ##

  def handle(%{action: :get, data: {fun, [key]}} = req, state) do
    fun = fn v ->
      put(:"$keys", [key])
      put(:"$map", (get(:"$value") && %{key: v}) || %{})

      # Transaction call should has no :"$value" key or :"$key"
      # — :"$map" and :"$keys" is used instead.

      delete(:"$value")
      delete(:"$key")

      fun.([v])
    end

    Req.handle(%{req | data: {key, fun}}, state)
  end

  ##
  ## MULTIPLE KEY HANDLERS
  ##

  ##
  ## prepair → collect → run → finalize
  ##

  def handle(req, state) do
    {fun, keys} = req.data

    Task.start_link(fn ->
      state = prepair(req, state)

      with {:ok, map} <- collect(req, state),
           put(:"$map", map),
           put(:"$keys", keys),
           values = Enum.map(keys, &map[&1]),
           {:ok, result} <- run(req, [values]),
           {:ok, get} <- finalize(req, result) do
        if get do
          GenServer.reply(req.from, get)
        end
      else
        {:error, :expired} ->
          r = inspect(req)
          ks = inspect(keys)
          Logger.error("Keys #{ks} transaction call has timed out. Request #{r}.")
          broadcast(key, :id, state)

        {:error, :callback} ->
          raise CallbackError, got: result

        {:error, :update} ->
          raise CallbackError, len: length(value_s)
      end
    end)
  end
end

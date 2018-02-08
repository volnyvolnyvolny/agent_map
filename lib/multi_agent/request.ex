defmodule MultiAgent.Req do
  @moduledoc false

  alias MultiAgent.{Callback, Worker, Transaction}

  import Worker, only: [dec: 1]
  import Callback, only: [parse: 1]

  import Map, only: [put: 3, get: 2]


  defstruct [:action,  # :get, :get_and_update, :update, :cast, …
             :data,    # {key, fun}, {fun, keys}, {key, fun, opts}
             :from,
             :expires, # date to which timeout is active
             !: false] # is not urgent by default


  defp to_msg(%Req{!: true}=req), do: {:!, to_msg %{req | :! => false}}
  defp to_msg(%Req{from: nil}=req), do: {req.action, req.data}
  defp to_msg(%Req{expires: nil}=req), do: {req.action, req.data, req.from}
  defp to_msg( req), do: {req.action, req.data, req.from, req.expires}


  def lookup( key, {:'$gen_call', _, req}), do: lookup key, req
  def lookup( key, {:'$gen_cast', req}), do: lookup key, req
  def lookup( key, %Req{data: {key,_}}=req) do
    if req.action in [:get_and_update, :update, :cast], do: :update, else: 1
  end
  def lookup( key, %Req{data: {_,keys}}=req) when is_list( keys) do
    if req.action in [:get_and_update, :update, :cast] do
      :update
    else
      if key in keys, do: 1, else: 0
    end
  end
  def lookup(_key,_req), do: 0


  # →
  defp handle(%Req{data: {_fun, keys}}=req, map) when is_list(keys) do
    {:noreply, Transaction.run( req, map)}
  end

  defp handle(%Req{action: :get, !: true}=req, map) do
    {key, fun} = req.data
    Task.start_link fn ->
      GenServer.reply req.from, Callback.run( fun, [get( map, key)])
    end

    {:noreply, map}
  end


  defp handle(%Req{action: :get}=req, map) do
    {key,fun} = req.data

    case map[key] do

      {:pid, worker} ->
        send worker, to_msg req
        {:noreply, map}

      {state,_late_call, t_num}=tuple when t_num > 1 -> # no need to check expires value
        server = self()
        Task.start_link fn ->
          GenServer.reply req.from, Callback.run( fun, [parse state])

          unless t_num == :infinity do
            send server, {:done_on_server, key}
          end
        end

        {:noreply, put( map, key, dec(tuple))}

      nil -> # no such key
        server = self()
        Task.start_link( fn ->
          GenServer.reply req.from, Callback.run( fun, [nil])
          send server, {:done_on_server, key}
        end)

        {:noreply, put( map, key, Worker.new_state())}

      {_,_,_}=tuple -> # max_threads forbids to spawn more Task's
        worker = spawn_link Worker, :loop, [self(), key, tuple]
        send worker, to_msg req

        {:noreply, put( map, key, {:pid, worker})}
    end
  end

  defp handle( req, map) do
    {key,fun} = req.data

    case map[key] do
      {:pid, worker} ->
        send worker, to_msg req
        {:noreply, map}

      tuple ->
        worker = spawn_link Worker, :loop, [self(), key, tuple]
        send worker, to_msg req
        {:noreply, put( map, key, {:pid, worker})}
    end
  end

end

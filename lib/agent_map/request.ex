defmodule AgentMap.Req do
  @moduledoc false

  alias AgentMap.{Callback, Worker, Transaction, Req, Value}

  import Value, only: [parse: 1, fmt: 1, dec: 1]


  defstruct [:action,  # :get, :get_and_update, :update, :cast, …
             :data,    # {key, fun}, {fun, keys}, {key, fun, opts}
             :from,
             :expires, # date to which timeout is active
             !: false] # is not urgent by default


  def to_msg(%Req{!: true}=req), do: {:!, to_msg %{req | !: false}}
  def to_msg(%Req{action: a, data: {_, fun}})
    when a in [:cast, {:one_key_t, :cast}], do: {a, fun}
  def to_msg(%Req{data: {_, fun}}=req), do: {req.action, fun, req.from, req.expires}


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


  def fetch( map, key) do
    case map do
      %{^key => {:pid, worker}} ->
        {_, dict} = Process.info worker, :dictionary
        Keyword.fetch dict, :'$state'

      %{^key => {{:state, state},_,_}} ->
        {:ok, state}

      _ -> :error
    end
  end


  # →
  def handle(%Req{action: :get, data: {fun, [key]}}=req, map) do
    handle %{req | data: {key, &Callback.run(fun, [[&1]])}}, map
  end

  def handle(%Req{data: {_fun, keys}}=req, map) when is_list(keys) do
    {:noreply, Transaction.run(req, map)}
  end

  def handle(%Req{action: :get, !: true}=req, map) do
    {key, fun} = req.data
    Task.start_link fn ->
      state = case fetch map, key do
        {:ok, state} -> state
        :error -> nil
      end

      GenServer.reply req.from, Callback.run(fun, [state])
    end

    {:noreply, map}
  end

  def handle(%Req{action: :get}=req, map) do
    {key,fun} = req.data

    case map[key] do
      {:pid, worker} ->
        send worker, to_msg req
        {:noreply, map}

      {state, late_call, quota} when quota > 1 ->
        server = self()
        Task.start_link fn ->
          GenServer.reply req.from, Callback.run(fun, [parse state])

          unless quota == :infinity do
            send server, {:done_on_server, key}
          end
        end

        {:noreply, put_in( map[key], {state, late_call, dec quota})}

      nil -> # no such key
        server = self()
        Task.start_link fn ->
          GenServer.reply req.from, Callback.run(fun, [nil])
          send server, {:done_on_server, key}
        end

        {:noreply, put_in( map[key], fmt %Value{})}

      {_, _, 1}=tuple -> # max_threads forbids to spawn more Task's
        worker = spawn_link Worker, :loop, [self(), key, tuple]
        send worker, to_msg req

        {:noreply, put_in( map[key], {:pid, worker})}
    end
  end

  def handle(%Req{action: :put}=req, map) do
    {key, state} = req.data

    map = case map do
      %{^key => {{:state, _}, lc, quota}} ->
        %{map | key => {{:state, state}, lc, quota}}

      %{^key => {:pid, worker}} ->
        send worker, to_msg %{req | action: :cast}
        map
      _ ->
        put_in map[key], fmt %Value{state: {:state, state}}
    end

    {:noreply, map}
  end

  def handle(%Req{action: :pop}=req, map) do
    {key, default} = req.data

    case fetch map, key do
      {:ok, _} ->
        handle %{req | action: :get_and_update,
                       data: {key, fn _ -> :pop end}}, map
      :error ->
        {:reply, default, map}
    end
  end


  def handle( req, map) do
    {key,_} = req.data

    case map[key] do
      {:pid, worker} ->
        send worker, to_msg req
        {:noreply, map}

      tuple ->
        worker = spawn_link Worker, :loop, [self(), key, tuple]
        send worker, to_msg req
        {:noreply, put_in( map[key], {:pid, worker})}
    end
  end

end

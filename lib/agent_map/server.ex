defmodule AgentMap.Server do
  @moduledoc false

  require Logger

  use GenServer

  alias AgentMap.{Worker, Multi}

  import Worker, only: [dict: 1, dec: 1, dec: 2, inc: 2, values: 1]
  import Enum, only: [map: 2, zip: 2, empty?: 1]
  import Task, only: [shutdown: 2]
  import Map, only: [put: 3, fetch: 2, delete: 2]

  #

  def to_fun({m, f, args}), do: &apply(m, f, [&1 | args])
  def to_fun(fun), do: fun

  #

  def spawn_worker({values, workers} = state, key, quota \\ 1) do
    if Map.has_key?(workers, key) do
      state
    else
      value? =
        case fetch(values, key) do
          {:ok, value} ->
            {value}

          :error ->
            nil
        end

      server = self()
      ref = make_ref()

      pid =
        spawn_link(fn ->
          Worker.loop({ref, server}, value?, quota)
        end)

      # hold …
      receive do
        {^ref, :resume} ->
          :_ok
      end

      # reserve quota
      inc(:processes, quota)

      #
      {delete(values, key), Map.put(workers, key, pid)}
    end
  end

  def extract_state({:noreply, state}), do: state
  def extract_state({:reply, _get, state}), do: state

  #

  ##
  ## GenServer callbacks
  ##

  @impl true
  def init(args) do
    timeout = args[:timeout]

    funs = args[:funs]
    keys = Keyword.keys(funs)

    results =
      funs
      |> map(fn {_key, fun} ->
        Task.async(fn ->
          try do
            {:ok, fun.()}
          rescue
            BadFunctionError ->
              {:error, :badfun}

            BadArityError ->
              {:error, :badarity}

            exception ->
              {:error, {exception, __STACKTRACE__}}
          end
        end)
      end)
      |> Task.yield_many(timeout)
      |> map(fn {task, res} ->
        res || shutdown(task, :brutal_kill)
      end)
      |> map(fn
        {:ok, result} ->
          result

        {:exit, _reason} = e ->
          {:error, e}

        nil ->
          {:error, :timeout}
      end)
      |> zip(keys)

    errors =
      for {{:error, reason}, key} <- results do
        {key, reason}
      end

    if empty?(errors) do
      Process.put(:max_p, args[:max_p])
      Process.put(:processes, 1)

      map =
        for {{:ok, v}, key} <- results, into: %{} do
          {key, v}
        end

      Process.put(:size, map_size(map))

      {:ok, {map, %{}}}
    else
      {:stop, errors}
    end
  end

  ##
  ## CALL / CAST
  ##

  @impl true
  # Agent.get(am, f):
  def handle_call({:get, f}, from, state) do
    handle_call(
      %Multi.Req{
        get: :all,
        upd: [],
        fun: &{to_fun(f).(&1), []},
        !: :avg
      },
      from,
      state
    )
  end

  # Agent.update(am, f):
  def handle_call({:update, f}, from, state) do
    handle_call({:get_and_update, &{:ok, to_fun(f)}}, from, state)
  end

  # Agent.get_and_update(am, f):
  def handle_call({:get_and_update, f}, from, state) do
    handle_call(
      %Multi.Req{
        get: :all,
        upd: :all,
        fun: to_fun(f),
        !: :avg
      },
      from,
      state
    )
  end

  #

  def handle_call(%r{} = req, from, state) do
    r.handle(%{req | from: from}, state)
  end

  #
  #

  @impl true
  def handle_cast({:cast, fun}, state) do
    resp = handle_call({:update, fun}, nil, state)
    {:noreply, extract_state(resp)}
  end

  #

  def handle_cast(%_{} = req, state) do
    resp = handle_call(req, nil, state)
    {:noreply, extract_state(resp)}
  end

  ##
  ## INFO
  ##

  # get task done its work after workers die
  @impl true
  def handle_info(%{info: :done}, state) do
    dec(:processes)

    {:noreply, state}
  end

  # worker asks to increase quota
  @impl true
  def handle_info({ref, worker, :more?}, state) do
    {soft, _h} = Process.get(:max_p)

    if Process.get(:processes) < soft do
      send(worker, {ref, %{act: :quota, inc: 1}})
      inc(:processes, +1)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({worker, :die?}, {values, workers} = state) do
    # Msgs could came during a small delay between
    # this call happen and :die? was sent.
    mq_len = Process.info(worker, :message_queue_len) |> elem(1)

    unless mq_len > 0 do
      #!
      dict = dict(worker)
      send(worker, :die!)

      #!
      value? = dict[:value?]

      p = dict[:processes]
      q = dict[:quota]

      #???
      key =
        case Enum.find(workers, fn {_key, pid} -> pid == worker end) do
          {key, _pid} ->
            key

          nil ->
            raise "This is an AgentMap-library design error. Please report it!"
        end

      values =
        if value? do
          Map.put(values, key, elem(value?, 0))
        end || values

      # return quota
      dec(:processes, q - p)

      {:noreply, {values, Map.delete(workers, key)}}
    else
      send(worker, :continue)

      {:noreply, state}
    end
  end

  ##
  ## CODE CHANGE
  ##

  @impl true
  def code_change(_old, state, fun) do
    # TODO: WRONG!!!
    {:noreply, apply(fun, [state])}
  end
end

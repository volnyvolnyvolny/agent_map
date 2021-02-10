defmodule AgentMap.Backend do
  @moduledoc false

  alias AgentMap.Storage.{ETS, DETS}

  def prep(ETS), do: prep({ETS, })

  @doc """
  Initialize backend, passing the default `data`.
  """
  def init(data, ETS), do: init(data, {ETS, []})

  def init(data, {ETS, opts}) do
    if Keyword.has_key?(opts, :name)  do
      ETS.new(opts[:name], [{:named_table, true} | Keyword.delete(opts, :name)])
    else
      ETS.new(:__data__, opts)
    end
    |> case do
      {:ok, table} ->
        {:ok, AgentMap.Storage.prepand(table, data)}

      err ->
        err
    end
  end


  # converts tuple that is stored in ETS and DETS
  # to {key, value, worker}
  defp tuple_to_kvw({key}), do: {key, nil, nil}
  defp tuple_to_kvw({key, value}), do: {key, value, nil}
  defp tuple_to_kvw({key, value, worker} = id) when is_pid(worker), do: id
  defp tuple_to_kvw({key, value, worker, }) when is_pid(worker), do: {key, nil, nil}


  def initialize(opts) do
    prep!(opts[:backend])
  end

  ##
  ## COUNT_WORKERS
  ##

  def count_workers({ETS, tab}) do
    raise :not_implemented_yet!
  end

  ##
  ## GET/INSERT
  ##

  @compile {:inline, insert: 3, get: 2, get: 3}

  def inc({ETS, tab}, key, step) do
    ETS.update_counter(tab, key, step)

    {ETS, tab}
  end

  def dec({ETS, tab}, key, step) do
    inc({ETS, tab}, key, -step)
  end

  def put(storage, key, value) when is_ets(storage) do
    unless ETS.update_element(tab, key, {2, {value}}) do
      # no value
      ETS.insert(tab, {key, {value}})
      # — the last insert wins
    end

    storage
  end

  def get({ETS, tab}, key, default \\ nil) do
    case ETS.lookup(tab, key) do
      [{^key, {value}}] ->
        value

      [{^key, {value}, _worker}] ->
        value

      [{^key, nil, _worker}] ->
        default

      [] ->
        default

      _multiple ->
        raise RuntimeError, "ETS has multiple values for a key #{inspect(key)}."
    end
  end

  def lock({ETS, tab}, key) do
    case ETS.lookup(tab, key) do
      [{^key, _value?, worker_or_lock}] ->
        {:error, worker_or_lock}

      [{^key, value?}] ->
        ETS.insert(tab, {key, value?, {:lock, self()}})
        :ok

      [] ->
        ETS.insert(tab, {key, nil, {:lock, self()}})
        :ok
    end
  end

  defp interpret(result) when length(result) > 1 do
    raise """
    Table with the bag type is used!
    AgentMap supports only :set and :ordered_set tables.
    """
  end

  defp interpret([{key, _value?}]), do: {:error, :noworker}
  defp interpret([{key, _value?, worker}]) when is_pid(worker), do: {:ok, worker}
  defp interpret([]), do: {:error, :missing}
  defp interpret({:error, _reason} = err), do: err

  def get_worker({module, table}, key) do
    table
    |> module.lookup(key)
    |> interpret()
  end
end

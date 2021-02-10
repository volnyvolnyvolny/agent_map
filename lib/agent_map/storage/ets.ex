defmodule AgentMap.Storage.ETS do
  import AgentMap.Storage

  @moduledoc """
  This module can be used to access raw `ETS` functions in the `Elixir` manner.
  """

  alias :ets, as: ETS

  @doc """
  Creates a new table and returns a table identifier that can be used in
  subsequent operations The table identifier can be sent to other processes so
  that a table can be shared between different processes within a node.

  Returns `{:ok, reference | atom}` or `{:error, reason}`.

  ## Options

    * `named_table: boolean`, `false` — to create `:named_table`;
    * `type: :set | :ordered_set | :bag | :duplicated_bag`, `:set`;
    * `access: :public | :protected | :private`, `:public`;
    * `compressed: boolean`, `false`;
    * `read_concurrency | write_concurrency : boolean`, `false`;
    * `keypos: integer ≥ 1`, `1`;
    * `heir: {pid, heir_data :: term} | :none`, `:none`;

    * `decentralized_counters: boolean`, when `write_concurrency: true` defaults
      to `true` for `ordered_set`s and `false` elsewise. Has no effect for the
      `write_concurrency: false`.

  See [ETS docs](http://erlang.org/doc/man/ets.html#new-2) for the details.
  """
  @spec new(atom, keyword) :: {:ok, ets} | {:error, reason}
  def new(name, opts) when is_atom(name) do
    erl_opts = prep(opts)
    :ets.new(name, )
  end

  @doc """
  Returns `true` if one or more elements in the table has `key`.
  """
  def has_key?(table, key) do
    ETS.member(table, key)
  end

  @doc """
  Converts options to the good old Erlang analogs.
  """
  @spec prep({atom, value}) :: :ok | {:ok, opt} | {:error, reason}
  @spec prep(keyword) :: {:ok, [term]} | {:error, reasons}
  def prep({:named_table, true}), do: {:ok, :named_table}
  def prep({:named_table, false}), do: :ok

  def prep({:type, t}) when t in [:set, :ordered_set, :bag, :duplicated_bag], do: {:ok, t}
  def prep({:keypos, kp} = opt) when is_integer(kp) and kp >= 1, do: {:ok, opt}
  def prep({:read_concurrency, rc} = opt) when is_boolean(rc), do: {:ok, opt}
  def prep({:write_concurrency, wc} = opt) when is_boolean(wc), do: {:ok, opt}
  def prep({:heir, h} = opt), do: {:ok, opt}
  def prep({:compressed, c} = opt) when is_boolean(b), do: {:ok, opt}
  def prep({:access, a}) when a in [:public, :protected, :private], do: {:ok, a}

  def prep({opt, value}) do
    if opt in [
      :named_table,
      :type,
      :keypos,
      :read_concurrency,
      :write_concurrency,
      :heir,
      :compressed
      :access
    ] do
      {:error, "Malformed value #{inspect(value)} for option #{opt}"}
    else
      {:error, "Unrecognized option #{opt}"}
    end
  end

  def prep(opts) do
    opts
    |> Enum.map(&prep/1)
    |> combine_errors()
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

  @doc """
  Returns a list of objects associated with `key`.
  """
  @spec lookup(ets, key) :: [value]
  def lookup(table, key) do
    ETS.lookup(table, key)
  end

  # @doc """
  # Fetches the value for a specific `key` in the given `table`.

  # Returns `{:ok, value}` or `:error` if the key is missing.

  # If the type of the `table` is `bag` or `duplicated_bag`, returns `{:ok,
  # [value]}` or `:error` if there is no object with `key`.
  # """
  # def fetch(table, key) do
  #   case ETS.lookup(table, key) do
  #     [] ->
  #       :error

  #     [value] ->
  #       if ETS.info(table, :type) in [:set, :ordered_set] do
  #         {:ok, value}
  #       else
  #         {:ok, [value]}
  #       end

  #     values ->
  #       {:ok, [values]}
  #   end
  # end

  def get(table, key, default \\ nil) do
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

  # TODO: add Mnesia
  def get_worker({module, table}, key) do
    table
    |> module.lookup(key)
    |> interpret()
  end

  @doc """
  Deletes all objects with `key` from `table`.

  Returns `:ok`.
  """
  def delete(table, key) do
    ETS.delete(table, key) && table
  end

  @doc """
  Deletes the entire `table`.

  Returns `:ok`.
  """
  def delete(table) do
    ETS.delete(table) && :ok
  end
end


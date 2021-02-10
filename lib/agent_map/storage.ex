defmodule AgentMap.Storage do
  @moduledoc false

  @type result :: term
  @type reason :: term

  defp combine({:ok, results}, {:ok, r}), do: {:ok, [r | results]}
  defp combine({:ok, results}, :error), do: {:error, [:noreason]}

  defp combine({:ok, _results} = id, :ok), do: id
  defp combine({:ok, _results}, {:error, reason}), do: {:error, [reason]}

  defp combine({:error, _reasons} = id, :ok), do: id
  defp combine({:error, _reasons} = id, {:ok, r}), do: id
  defp combine({:error, _reasons} = id, :error), do: id

  defp combine({:error, reasons}, {:error, r}), do: {:error, [r | reasons]}

  @doc """
  Combines results in the form of `:ok`, `{:ok, result}`, `:error`, `{:error,
  reason}`.

  Returns `{:ok, results}` or `{:error, reasons}`.
  """
  @spec combine_errors(
    [:ok | {:ok, result} | :error | {:error, reason}]
  ) :: {:ok, [result]} | {:error, [reason]}
  def combine_errors(results) do
    for result <- results, reduce: {:ok, []} do
      acc -> combine(acc, result)
    end
  end
end

defmodule Hun.Storage do
  @moduledoc false

  def get(storage, key) do
    case :ets.lookup(storage, key) do
      [] ->
        :error

      [{^key, value}] ->
        {:ok, value}
    end
  end

  def get!(storage, key) do
    get(storage, key) |> elem(1)
  end

  def get!(storage, key, default) do
    case get(storage, key) do
      {:ok, data} ->
        data

      :error ->
        default
    end
  end

  def put(storage, key, value) do
    :ets.insert(storage, {key, value})
    storage
  end

  def put_new(storage, key, value) do
    :ets.insert_new(storage, {key, value})
    storage
  end

  def delete(storage, key) do
    :ets.delete(storage, key)
    storage
  end

  def get_and_put(storage, key, default) do
    case get(storage, key) do
      {:ok, value} ->
        value

      :error ->
        put(storage, key, default)
        default
    end
  end

  def inc(storage, key, step) do
    was = get_and_put(storage, key, 0.0)
    put(storage, key, was + step)
    storage
  end
end

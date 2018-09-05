defmodule AgentMap.Common do
  @moduledoc false

  import System, only: [system_time: 0, convert_time_unit: 3]

  ##
  ## TIME RELATED
  ##

  def now(), do: system_time()

  def to_native(t) do
    convert_time_unit(t, :milliseconds, :native)
  end

  def to_ms(t) do
    convert_time_unit(t, :native, :milliseconds)
  end

  defp expired?(inserted_at, timeout) do
    now() >= inserted_at + to_native(timeout)
  end

  ##
  ## APPLY AND RUN
  ##

  def run(fun, arg, %{timeout: {:break, t}, inserted_at: i}) do
    import Process, only: [get: 1, put: 2]

    if expired?(i, t) do
      {:error, :expired}
    else
      {k, b} = {get(:"$key"), get(:"$value")}
      {ks, m, r, ws} = {get(:"$keys"), get(:"$map"), get(:"$ref"), get(:"$workers")}

      task =
        Task.async(fn ->
          if ks do
            put(:"$keys", ks)
            put(:"$map", m)
            put(:"$ref", r)
            put(:"$workers", ws)
          else
            put(:"$key", k)
            put(:"$value", b)
          end

          fun.(arg)
        end)

      case Task.yield(task, t) || Task.shutdown(task) do
        {:ok, _result} = res ->
          res

        nil ->
          {:error, :toolong}
      end
    end
  end

  def run(fun, arg, %{timeout: {:drop, t}, inserted_at: i}) do
    if expired?(i, t) do
      {:error, :expired}
    else
      {:ok, fun.(arg)}
    end
  end

  def run(fun, arg, _opts), do: {:ok, fun.(arg)}

  def reply(nil, _msg), do: :nothing
  def reply(from, msg), do: GenServer.reply(from, msg)
end

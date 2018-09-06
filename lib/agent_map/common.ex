defmodule AgentMap.Common do
  @moduledoc false

  import System, only: [system_time: 0, convert_time_unit: 3]

  ##
  ## TIME RELATED
  ##

  def to_ms(t) do
    convert_time_unit(t, :native, :milliseconds)
  end

  def to_native(t) do
    convert_time_unit(t, :milliseconds, :native)
  end

  def now(), do: system_time()

  defp expired?(inserted_at, timeout) do
    now() >= inserted_at + to_native(timeout)
  end

  def left(:infinity, _), do: :infinity

  def left(timeout, since: past) do
    timeout - to_ms(now() - past)
  end

  ##
  ## APPLY AND RUN
  ##

  def run(fun, args, opts \\ []) do
    timeout = opts[:timeout]
    inserted_at = opts[:inserted_at]

    if timeout && expired?(inserted_at, timeout) do
      {:error, :expired}
    else
      if opts[:break] do
        dict = Process.info(self())[:dictionary]

        task =
          Task.async(fn ->
            for {k, v} <- dict do
              Process.put(k, v)
            end

            apply(fun, args)
          end)

        t = left(timeout, since: inserted_at)

        case Task.yield(task, t) || Task.shutdown(task) do
          {:ok, _result} = res ->
            res

          nil ->
            {:error, :toolong}
        end
      else
        {:ok, apply(fun, args)}
      end
    end
  end

  def reply(nil, _msg), do: :nothing
  def reply(from, msg), do: GenServer.reply(from, msg)
end

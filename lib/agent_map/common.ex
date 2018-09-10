defmodule AgentMap.Common do
  @moduledoc false

  import System, only: [system_time: 0, convert_time_unit: 3]

  ##
  ## TIME RELATED
  ##

  def to_ms(t) do
    convert_time_unit(t, :native, :milliseconds)
  end

  def now(), do: system_time()

  def left(:infinity, _), do: :infinity

  def left(timeout, since: past) do
    timeout - to_ms(now() - past)
  end

  ##
  ## APPLY AND RUN
  ##

  def run(_fun, _args, timeout, _break?) when timeout <= 0 do
    {:error, :expired}
  end

  def run(fun, args, _timeout, false), do: {:ok, apply(fun, args)}

  def run(fun, args, timeout, true) do
    dict = Process.info(self())[:dictionary]

    past = now()

    task =
      Task.async(fn ->
        for {k, v} <- dict do
          Process.put(k, v)
        end

        apply(fun, args)
      end)

    spent = to_ms(now() - past)

    case Task.yield(task, timeout - spent) || Task.shutdown(task) do
      {:ok, _result} = res ->
        res

      nil ->
        {:error, :toolong}
    end
  end

  def reply(nil, _msg), do: :nothing
  def reply(from, msg), do: GenServer.reply(from, msg)
end

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

  def run(_fun, _args, timeout) when timeout <= 0 do
    {:error, :expired}
  end

  def run(fun, args, _timeout) do
    {:ok, apply(fun, args)}
  end

  def reply(nil, _msg), do: :nothing
  def reply({_p, _ref} = from, msg), do: GenServer.reply(from, msg)
  def reply(from, msg), do: send(from, msg)
end

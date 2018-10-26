defmodule AgentMap.Time do
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
end

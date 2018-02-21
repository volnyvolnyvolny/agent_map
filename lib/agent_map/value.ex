defmodule AgentMap.Value do
  @moduledoc false

  alias AgentMap.Value


  @compile {:inline, parse: 1}


  defstruct [:state,
             late_call: false,
             max_threads: 5]

  def fmt(%Value{}=v), do: {v.state, v.late_call, v.max_threads}


  def parse({:state, state}), do: state
  def parse(nil), do: nil


  def dec(:infinity), do: :infinity
  def dec(i) when is_integer(i), do: i-1

  def inc(:infinity), do: :infinity
  def inc(i) when is_integer(i), do: i+1
end

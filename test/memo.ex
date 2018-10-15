defmodule Memo do
  use AgentMap

  def start_link() do
    AgentMap.start_link([], name: __MODULE__)
  end

  def stop(), do: AgentMap.stop(__MODULE__)

  @doc """
  If `{task, arg}` key is known — return it,
  else, invoke given `fun` as a Task, writing
  result under `{task, arg}` key.
  """
  def calc(task, fun, arg) do
    AgentMap.get_and_update(__MODULE__, {task, arg}, fn
      nil ->
        res = fun.(arg)
        {res, res}

      _value ->
        # Change nothing, return current value.
        :id
    end)
  end
end

defmodule Calc do
  def fib(0), do: 0
  def fib(1), do: 1

  def fib(n) when n >= 0 do
    Memo.calc(:fib, fn n -> fib(n - 1) + fib(n - 2) end, n)
  end
end

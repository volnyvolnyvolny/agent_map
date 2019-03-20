defmodule AgentMap.Bench do
  def ets(range) do
    table = :ets.new(:test, [:protected, :set])

    for k <- range, v <- range do
      :ets.insert(table, {k, v})
    end

    f = fn ->
      :ets.lookup(table, 666)
    end

    m..n = range

    Benchee.run(%{
      "ets read #{n - m + 1}" => f
    })

    Benchee.run(%{
      "ets read #{n - m + 1}, p=2" => f
    }, parallel: 2)

    Benchee.run(%{
      "ets read #{n - m + 1}, p=3" => f
    }, parallel: 3)

    Benchee.run(%{
      "ets read #{n - m + 1}, p=4" => f
    }, parallel: 4)
  end
end

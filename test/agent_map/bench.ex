defmodule AgentMap.Bench do
  @moduledoc """
  Benchmarks.

  To run use `mix bench` or `run/2`.
  """

  @type size :: pos_integer
  @type reads :: pos_integer

  defp setup(obj, {size, iterations}) do
    setup(obj, size, iterations)
  end

  defp setup(obj, size, iterations) when obj in [Map, AgentMap] do
    m =
      Enum.reduce(1..size, obj.new(), fn k, map ->
        value = Enum.random(1..size)
        obj.put(map, k, value)
      end)

    {m, iterations}
  end

  defp setup(ETS, size, iterations) do
    name = :"#{inspect({size, iterations})}"
    table = :ets.new(name, [read_concurrency: true])

    for k <- 1..size do
      value = Enum.random(1..size)
      :ets.insert(table, {k, value})
    end

    {table, iterations}
  end

  defp setup(Agent, size, iterations) do
    {map, _} = setup(Map, size, iterations)

    {:ok, agent} = Agent.start(fn -> map end)

    {agent, iterations}
  end

  #
  defp teardown(obj, {id, iterations}) do
    teardown(obj, id, iterations)
  end

  defp teardown(ETS, table, _i) do
    :ets.delete(table)
  end

  defp teardown(AgentMap, am, _i) do
    AgentMap.stop(am)
  end

  defp teardown(Agent, a, _i) do
    Agent.stop(a)
  end

  defp teardown(_o, _, _), do: :noop

  #

  def scenario(obj, fun) do
    {
      fun,
      before_scenario: &setup(obj, &1),
      after_scenario: &teardown(obj, &1)
    }
  end

  #


  # Supported `cases` are:

  #   * `ETS` — read (`:ets.lookup/2`) and write (`:ets.insert/2`) to `ETS`;

  #   * `Map` — read (`Map.get/2`) and write (`Map.put/3`) to `Map`;

  #   * `AgentMap` — read (`AgentMap.get/2`) and write (`AgentMap.put/3`) to an
  #     `AgentMap` instance;

  #   * `Agent` — read (`Agent.get(agent, &Map.get(&1, key))`) and write
  #     (`Agent.update(agent, &Map.put(&1, key, new_value))`).

  @doc """
  Run benchmarks.
  """
  @spec run(keyword) :: no_return
  def run(benchee_opts \\ []) do
    # :)
    datasets =
      [
        "100 from 1_000": {1_000, 100},
        "1_000 from 10_000": {1_000, 10_000},
        "10_000 from 100_000": {10_000, 100_000},
        "100_000 from 1_000_000": {100_000, 1_000_000}
      ]

    Benchee.run(%{
      ":ets.lookup/2" =>
        scenario(ETS, fn {t, n} ->
          for k <- 1..n do
            :ets.lookup(t, div(k * 342, 7))
          end
        end),

      "Map.get/2" =>
        scenario(Map, fn {m, n} ->
          for k <- 1..n do
            Map.get(m, div(k * 342, 7))
          end
        end),

      "AgentMap.get/2" =>
        scenario(AgentMap, fn {m, n} ->
          for k <- 1..n do
            AgentMap.get(m, div(k * 342, 7))
          end
        end),

      "Agent.get(a, &Map.get(&1, key))" =>
        scenario(Agent, fn {a, n} ->
          for k <- 1..n do
            Agent.get(a, &Map.get(&1, div(k * 342, 7)))
          end
        end)
    }, [{:inputs, datasets} | benchee_opts])
  end
end

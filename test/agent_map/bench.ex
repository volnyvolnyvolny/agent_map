defmodule AgentMap.Bench do
  @moduledoc """
  Benchmarks.

  To run use `mix bench` or `run/2`.
  """

  import Process, only: [sleep: 1]

  @ets_opts [read_concurrency: true, write_concurrency: true]

  defp setup(Map, size) do
    Enum.reduce(1..size, Map.new(), fn k, map ->
      value = Enum.random(1..size)
      Map.put(map, k, value)
    end)
  end

  defp setup(ETS, size) do
    table = :ets.new(:"ETS / #{size}", @ets_opts)

    for k <- 1..size do
      value = Enum.random(1..size)
      :ets.insert(table, {k, value})
    end

    table
  end

  defp setup(Agent, size) do
    {:ok, agent} =
      Agent.start(fn ->
        setup(Map, size)
      end)

    agent
  end

  defp setup(AgentMap, size), do: AgentMap.new(setup(Map, size))


  #
  defp teardown(ETS, table), do: :ets.delete(table)
  defp teardown(obj, o) when obj in [Agent, AgentMap], do: obj.stop(o)
  defp teardown(Map, _m), do: :nothing

  #

  defp benchee_run(s_name, suite, opts) do
    only =
      if opts[:only] do
        Enum.map(opts[:only], &name(s_name, &1))
      end || Map.keys(suite)

    datasets =
      for p <- opts[:powers] || 3..6 do
        {size, iterations} =
          {floor(:math.pow(10, p)), floor(:math.pow(10, p - 1))}

        {"#{iterations} from #{size}", {size, iterations}}
      end

    benchee_opts =
      opts
      |> Keyword.delete(:only)
      |> Keyword.delete(:powers)

    Benchee.run(Map.take(suite, only), [{:inputs, datasets} | benchee_opts])
  end

  #

  defp scenario(obj, fun) do
    {
      fun,
      before_scenario: fn {size, iterations} ->
        {setup(obj, size), size, iterations}
      end,
      after_scenario: fn {o, _size, _iterations} ->
        teardown(obj, o)
      end
    }
  end

  #

  defp name(suite, obj)

  #

  defp name(:lookup, ETS), do: ":ets.lookup(table, key)"
  defp name(:lookup, Map), do: "&(Map.get(&1, key)).(map)"
  defp name(:lookup, Agent), do: "Agent.get(a, &Map.get(&1, key))"
  defp name(:lookup, AgentMap), do: "AgentMap.get(am, key)"

  #

  defp name(:insert, ETS), do: ":ets.insert(table, {key, :value})"
  defp name(:insert, Agent), do: "Agent.update(a, &Map.put(&1, key, :value))"
  defp name(:insert, AgentMap), do: "AgentMap.put(am, key, :value)"

  #

  defp name(:lookup_insert, ETS), do: "ETS insert + lookup"
  defp name(:lookup_insert, Agent), do: "Agent insert + lookup"
  defp name(:lookup_insert, AgentMap), do: "AgentMap insert + lookup"

  #

  defp name(:counter, ETS), do: "ETS update_counter + lookup"
  defp name(:counter, Agent), do: "Agent.update (Map.update + Map.get)"
  defp name(:counter, AgentMap), do: "AgentMap.Utils.inc(am, key)"

  #

  defp name(:update, Agent), do: "Agent.update (Map.update [sleep(1) + inc] + Map.get)"
  defp name(:update, AgentMap), do: "AgentMap.update(am, key, [sleep(1) + inc])"

  #

  @doc """
  Run benchmarks with `scenario`.

  ## Options

    * `Benchee` opts;
    * `only: [scenario name]`.
  """
  @spec run(atom, keyword) :: no_return
  def run(suite, opts \\ [])

  def run(:lookup = s_name, opts) do
    suite = %{
      name(s_name, ETS) =>
        scenario(ETS, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n, do: :ets.lookup(obj, k * d)
        end),

      name(s_name, Map) =>
        scenario(Map, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n, do: (&Map.get(&1, k * d)).(obj)
        end),

      # "Map.get/2" =>
      #   scenario(Map, fn {obj, size, n} ->
      #     d = 2 * floor(size / n)

      #     for k <- 1..n do
      #       Map.get(obj, k * d)
      #     end
      #   end),

      name(s_name, AgentMap) =>
        scenario(AgentMap, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n, do: AgentMap.get(obj, k * d)
        end),

      name(s_name, Agent) =>
        scenario(Agent, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n, do: Agent.get(obj, &Map.get(&1, k * d))
        end)
    }

    benchee_run(s_name, suite, opts)
  end

  def run(:insert = s_name, opts) do
    suite = %{
      name(s_name, ETS) =>
        scenario(ETS, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n, do: :ets.insert(obj, {k * d, :value})
        end),

      name(s_name, AgentMap) =>
        scenario(AgentMap, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n, do: AgentMap.put(obj, k * d, :value)
        end),

      name(s_name, Agent) =>
        scenario(Agent, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n, do: Agent.update(obj, &Map.put(&1, k * d, :value))
        end)
    }

    benchee_run(s_name, suite, opts)
  end

  def run(:lookup_insert = s_name, opts) do
    suite = %{
      name(s_name, ETS) =>
        scenario(ETS, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            :ets.insert(obj, {k * d, :value})
            :ets.lookup(obj, k * d)
          end
        end),

      name(s_name, AgentMap) =>
        scenario(AgentMap, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            AgentMap.put(obj, k * d, :value)
            AgentMap.get(obj, k * d)
          end
        end),

      name(s_name, Agent) =>
        scenario(Agent, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            Agent.update(obj, &Map.put(&1, k * d, :value))
            Agent.get(obj, &Map.get(&1, k * d))
          end
        end)
    }

    benchee_run(s_name, suite, opts)
  end

  def run(:counter = s_name, opts) do
    suite = %{
      name(s_name, ETS) =>
        scenario(ETS, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            key = k * d
            :ets.update_counter(obj, key, 1, {key, 0})
            :ets.lookup(obj, key)
          end
        end),

      name(s_name, AgentMap) =>
        scenario(AgentMap, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            key = k * d
            AgentMap.Utils.inc(obj, key)
            AgentMap.get(obj, key)
          end
        end),

      name(s_name, Agent) =>
        scenario(Agent, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            key = k * d
            Agent.update(obj, &Map.update(&1, key, 1, fn v -> v + 1 end))
            Agent.get(obj, &Map.get(&1, key))
          end
        end)
    }

    benchee_run(s_name, suite, opts)
  end

  def run(:update = s_name, opts) do
    upd = &(sleep(100) && &1 + 1)

    suite = %{
      name(s_name, AgentMap) =>
        scenario(AgentMap, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            key = k * d
            AgentMap.update(obj, key, upd, initial: 0)
            AgentMap.get(obj, key)
          end
        end),

      name(s_name, Agent) =>
        scenario(Agent, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            key = k * d
            Agent.update(obj, &Map.update(&1, key, 1, upd))
            Agent.get(obj, &Map.get(&1, key))
          end
        end)
    }

    benchee_run(s_name, suite, opts)
  end
end

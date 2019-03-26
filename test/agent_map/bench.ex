defmodule AgentMap.Bench do
  @moduledoc """
  Benchmarks.

  To run use `mix bench` or `run/2`.
  """

  defp setup(Map, size) do
    Enum.reduce(1..size, Map.new(), fn k, map ->
      value = Enum.random(1..size)
      Map.put(map, k, value)
    end)
  end

  defp setup(ETS, size) do
    table = :ets.new(:"ETS / #{size}", read_concurrency: true, write_concurrency: true)

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

  #

  defp benchee_run(s_name, suite, opts) do
    only =
      if opts[:only] do
        Enum.map(opts[:only], &name(s_name, &1))
      end || Map.keys(suite)

    datasets =
      for p <- opts[:pows] || 3..6 do
        {size, iterations} =
          {floor(:math.pow(10, p)), floor(:math.pow(10, p - 1))}

        {"#{iterations} from #{size}", {size, iterations}}
      end

    benchee_opts =
      opts
      |> Keyword.delete(:only)
      |> Keyword.delete(:pows)

    # # :)
    # datasets =
    #   [
    #     "100 from 1_000": {1_000, 100},
    #     # "1_000 from 10_000": {1_000, 10_000},
    #     # "10_000 from 100_000": {10_000, 100_000},
    #     # "100_000 from 1_000_000": {100_000, 1_000_000}
    #   ]

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

  defp name(:lookup_insert, ETS), do: "ETS lookup/insert"
  defp name(:lookup_insert, Agent), do: "Agent lookup/insert"
  defp name(:lookup_insert, AgentMap), do: "AgentMap lookup/insert"

  #

  @doc """
  Run benchmarks with `scenario`.

  ## Options

    * `Benchee` opts;
    * `only: [scenario name]`.
  """
  @spec run(atom, keyword) :: no_return
  def run(suite, opts \\ [])

  # def run(:state, benchee_opts) do
  #   # :)
  #   datasets =
  #     [
  #       "100 from 1_000": {1_000, 100},
  #       # "1_000 from 10_000": {1_000, 10_000},
  #       # "10_000 from 100_000": {10_000, 100_000},
  #       # "100_000 from 1_000_000": {100_000, 1_000_000}
  #     ]

  #   benchee_opts = [{:inputs, datasets} | ++ benchee_opts

  #   #

  #   Benchee.run(%{
  #     "ets_read_write" =>
  #       fn {global, _, _} ->

  #         :ets.insert(global, {:value, 42})   # write
  #         :ets.lookup(global, :value) |> hd() # read
  #       end,

  #     "agent_read_write" =>
  #       fn {_, agent, _} ->
  #         Agent.update(agent, fn _ ->
  #           {:value, 42}
  #         end)

  #         Agent.get(agent, &{:value, &1})
  #       end,

  #     "agent_with_p_dict" =>
  #       fn {_, _, p_dict} ->
  #         Agent.update(p_dict, fn _ ->
  #           Process.put(:value, 42)
  #         end)

  #         Process.info(p_dict, :dictionary) |> elem(1) |> hd()
  #       end
  #   },
  #   [
  #     before_scenario: fn _ ->
  #     global = :ets.new(:global, [])

  #     {:ok, agent} = Agent.start(fn -> {:value, nil} end)
  #     {:ok, p_dict} = Agent.start(fn -> :no_state end)

  #     {global, agent, p_dict}
  #     end
  #   ])
  # end

  def run(:lookup = s_name, opts) do
    suite = %{
      name(s_name, ETS) =>
        scenario(ETS, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            :ets.lookup(obj, k * d)
          end
        end),

      name(s_name, Map) =>
        scenario(Map, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            (&Map.get(&1, k * d)).(obj)
          end
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

          for k <- 1..n do
            AgentMap.get(obj, k * d)
          end
        end),

      name(s_name, Agent) =>
        scenario(Agent, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            Agent.get(obj, &Map.get(&1, k * d))
          end
        end)
    }

    benchee_run(s_name, suite, opts)
  end

  def run(:insert = s_name, opts) do
    suite = %{
      name(s_name, ETS) =>
        scenario(ETS, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            :ets.insert(obj, {k * d, :value})
          end
        end),

      name(s_name, AgentMap) =>
        scenario(AgentMap, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            AgentMap.put(obj, k * d, :value)
          end
        end),

      name(s_name, Agent) =>
        scenario(Agent, fn {obj, size, n} ->
          d = 2 * floor(size / n)

          for k <- 1..n do
            Agent.update(obj, &Map.put(&1, k * d, :value))
          end
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
end

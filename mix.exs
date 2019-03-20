defmodule AgentMap.Mixfile do
  use Mix.Project

  def project do
    [
      app: :agent_map,
      name: "AgentMap",
      description: """
      AgentMap can be seen as a stateful Map that parallelize operations made on
      different keys. Basically, it can be used as a cache, memoization,
      computational framework and, sometimes, as an alternative to GenServer.
      """,
      version: "1.1.2",
      elixir: "~> 1.8",
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test", "test/agent_map"]
  defp elixirc_paths(:dev), do: ["lib", "test/agent_map"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:heap, "~> 2.0"},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false},
      {:credo, "~> 1.0", only: :dev},
      {:benchee, "~> 0.14", only: :test}
    ]
  end

  defp aliases do
    [
      quality: [
        "format",
        "credo --strict"
      ]
    ]
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme"
    ]
  end

  defp package do
    [
      maintainers: ["Valentin Tumanov (Vasilev)"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/zergera/agent_map",
        "Docs" => "http://hexdocs.pm/agent_map"
      }
    ]
  end
end

defmodule AgentMap.Mixfile do
  use Mix.Project

  def project do
    [
      app: :agent_map,
      name: "AgentMap",
      description: """
        `AgentMap` can be seen as a stateful `Map` that parallelize operations
        made on different keys. Basically, it can be used as a cache,
        memoization, computational framework and, sometimes, as a `GenServer`
        replacement.
      """,
      version: "1.0.1",
      elixir: "~> 1.7",
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:heap, "~> 2.0"},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false},
      {:credo, "~> 0.10", only: :dev}
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
      extras: ["README.md"],
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

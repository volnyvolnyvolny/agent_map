defmodule AgentMap.Mixfile do
  use Mix.Project

  def project do
    [
      app: :agent_map,
      name: "AgentMap",
      description: """
        `AgentMap` is a `GenServer` that holds `Map` and provides concurrent
        access for operations made on different keys. Basically, it can be used
        as a cache, memoization and computational framework or, sometimes, as a
        `GenServer` replacement.
      """,
      version: "1.0.0",
      elixir: "~> 1.6.0",
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
      {:earmark, "~> 1.2", only: :dev},
      {:ex_doc, "~> 0.18", only: :dev},
      {:credo, "~> 0.8.10", only: :dev}
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
      maintainers: ["Valentin Tumanov"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/zergera/agent_map",
        "Docs" => "http://hexdocs.pm/agent_map"
      }
    ]
  end
end

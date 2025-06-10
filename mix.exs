defmodule Phantom.MixProject do
  use Mix.Project

  def project do
    [
      aliases: aliases(),
      app: :phantom,
      description: "Elixir MCP (Model Context Protocol) server library with Plug",
      deps: deps(),
      docs: docs(),
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: "0.1.0",
      source_url: "https://github.com/dbernheisel/phantom_mcp"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    if Mix.env() == :test do
      [
        mod: {Test.Application, []},
        extra_applications: [:logger, :runtime_tools]
      ]
    else
      [
        extra_applications: [:logger]
      ]
    end
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:dev), do: ["lib"]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:uuidv7, "~> 1.0"},
      ## Dev
      {:tidewave, "~> 0.1", only: [:test]},
      {:phoenix, "~> 1.7", only: [:dev, :test]},
      {:bandit, "~> 1.7", only: [:test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["David Bernheisel"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/dbernheisel/phantom_mcp"
      }
    ]
  end

  defp docs do
    [
      main: "Phantom",
      extras: ~w[CHANGELOG.md]
    ]
  end

  defp aliases do
    []
  end
end

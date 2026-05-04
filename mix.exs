defmodule Phantom.MixProject do
  use Mix.Project

  def project do
    [
      compilers: Mix.compilers(),
      app: :phantom_mcp,
      description: "Elixir MCP (Model Context Protocol) server library with Plug",
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit]],
      docs: docs(),
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: escript(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: "0.4.5",
      source_url: "https://github.com/dbernheisel/phantom_mcp"
    ]
  end

  def cli do
    [
      preferred_envs: [tidewave: :test, format: :test, dialyzer: :test]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]

  defp elixirc_paths(:stdio), do: ["lib", "test/support/app"]

  defp elixirc_paths(_), do: ["lib"]

  defp escript(:stdio), do: [main_module: Test.Stdio, app: nil]
  defp escript(_), do: []

  defp deps do
    [
      {:plug, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.0", optional: true, only: [:dev, :test, :prod, :stdio]},
      {:uuidv7, "~> 1.0"},
      ## Test
      {:phoenix_live_view, "~> 1.0", only: [:dev, :test, :stdio]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, warn_if_outdated: true, runtime: false},
      {:tidewave, "~> 0.5", only: [:dev, :test], warn_if_outdated: true},
      {:makeup_javascript, "~> 0.1", only: :dev},
      {:phoenix_live_reload, "~> 1.5", only: [:dev, :test, :stdio]},
      {:bandit, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      name: :phantom_mcp,
      maintainers: ["David Bernheisel"],
      licenses: ["MIT"],
      links: %{
        "MCP Specification" => "https://modelcontextprotocol.io",
        "MCP Inspector" => "https://github.com/modelcontextprotocol/inspector",
        "GitHub" => "https://github.com/dbernheisel/phantom_mcp"
      }
    ]
  end

  @mermaidjs """
  <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.2.3/dist/mermaid.min.js"></script>
  <script>
    let initialized = false;

    window.addEventListener("exdoc:loaded", () => {
      if (!initialized) { mermaid.initialize({
          startOnLoad: false,
          theme: document.body.className.includes("dark") ? "dark" : "default"
        });
        initialized = true;
      }

      let id = 0;
      for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
        const preEl = codeEl.parentElement;
        const graphDefinition = codeEl.textContent;
        const graphEl = document.createElement("div");
        const graphId = "mermaid-graph-" + id++;
        mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
          graphEl.innerHTML = svg;
          bindFunctions?.(graphEl);
          preEl.insertAdjacentElement("afterend", graphEl);
          preEl.remove();
        });
      }
    });
  </script>
  """

  defp docs do
    [
      main: "Phantom",
      extras: ["guides/mcp_apps.md", "CHANGELOG.md"],
      before_closing_body_tag: %{html: @mermaidjs}
    ]
  end
end

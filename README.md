# Phantom MCP

[![Hex.pm](https://img.shields.io/hexpm/v/phantom_mcp.svg)](https://hex.pm/packages/phantom_mcp)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/phantom_mcp)

MCP (Model Context Protocol) framework for Elixir Plug.

Phantom implements the [MCP server specification](https://modelcontextprotocol.io/specification)
over Streamable HTTP and stdio. Declare tools, prompts, and resources in a
router, the way a Phoenix router declares routes, and Phantom handles the
protocol: sessions, SSE streams, clustering, elicitation, and the stateless
`2026-07-28` core. The same router can serve [A2A](https://a2a-protocol.org)
agents.

## Installation

```elixir
def deps do
  [
    {:phantom_mcp, "~> 0.8.0"}
  ]
end
```

## Quick start

Define a router with a tool:

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0",
    instructions: "Tools for greeting people"

  tool :greet, description: "Greet someone by name" do
    field :name, :string, required: true
  end

  def greet(%{"name" => name}, session) do
    {:reply, Phantom.Tool.text("Hello, #{name}!"), session}
  end
end
```

Forward a path to it from your Phoenix router:

```elixir
pipeline :mcp do
  plug :accepts, ["json", "sse"]

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON
end

scope "/mcp" do
  pipe_through :mcp
  forward "/", Phantom.Plug, router: MyApp.MCP.Router
end
```

And accept SSE:

```elixir
# config/config.exs
config :mime, :types, %{"text/event-stream" => ["sse"]}
```

Your server is now at `http://localhost:4000/mcp`. Try it with the
[MCP Inspector](https://modelcontextprotocol.io/docs/tools/inspector).

## Guides

Start with [Getting Started](guides/getting_started.md), which covers
`Plug.Router` and stdio too.

- [Tools](guides/tools.md), [Prompts](guides/prompts.md), and
  [Resources](guides/resources.md)
- [Authentication](guides/authentication.md)
- [Elicitation](guides/elicitation.md)
- [Testing](guides/testing.md)
- [Deployment](guides/deployment.md): load balancers, clustering, caching,
  and tracing
- [Protocol Support](guides/protocol_support.md)

Extensions:

- [Tasks](guides/tasks.md)
- [Skills](guides/skills.md)
- [MCP Apps](guides/mcp_apps.md)
- [OAuth Client Credentials](guides/oauth_client_credentials.md)

And [A2A agents](guides/a2a.md).

## License

MIT License.

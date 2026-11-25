# Getting Started

This guide adds an MCP server to an Elixir application: install Phantom,
pick a transport, and define the router that lists your tools, prompts, and
resources.

## Installation

Add Phantom to your dependencies:

```elixir
def deps do
  [
    {:phantom_mcp, "~> 0.8.0"}
  ]
end
```

Then import the formatter settings in your `.formatter.exs`, so the router
macros format without parentheses. Below uses Phoenix's generated file as a
starting point:

```elixir
[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phantom_mcp],
  # ...
]
```

## Define the router

The MCP router catalogs your tools, prompts, and resources, and authenticates
each request. Start with an empty one:

```elixir
defmodule MyApp.MCP.Router do
  @moduledoc """
  Provides tools, prompts, and resources to aid in researching
  topics and creating research studies using MyApp.
  """

  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0", # or Application.spec(:my_app, :vsn)
    instructions: @moduledoc
end
```

This uses the `@moduledoc` as the instructions for the client; feel free to
separate the instructions from internal documentation.

> #### Instructions and descriptions are important! {: .neutral}
>
> These instructions and descriptions for tools, prompts, and resources
> will be used by the LLM to determine when and how to use your tooling.
> Don't be too verbose, but also don't have vague instructions.

See `Phantom.Router` for every option `use Phantom.Router` accepts.

## Choose a transport

Phantom serves the router over Streamable HTTP for remote clients, or over
stdio for local clients. You can serve both from the same router.

### Streamable HTTP (remote clients)

Configure MIME to accept SSE:

```elixir
# config/config.exs
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}
```

Then forward a path from your Plug or Phoenix router to `Phantom.Plug`.

<!-- tabs-open -->

### Phoenix

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  # ...

  pipeline :mcp do
    plug :accepts, ["json", "sse"]

    plug Plug.Parsers,
      parsers: [{:json, length: 1_000_000}],
      pass: ["application/json"],
      json_decoder: JSON
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", Phantom.Plug,
      # Uncomment for remote access from anywhere:
      # origins: :all,
      # Uncomment for remote access from a specified list:
      # origins: ["https://myapp.example"],
      # Uncomment for a server bound to localhost, to reject DNS rebinding:
      # hosts: ["localhost", "127.0.0.1", "[::1]"],
      validate_origin: Mix.env() == :prod,
      router: MyApp.MCP.Router
  end
end
```

### Plug.Router

```elixir
defmodule MyAppWeb.Router do
  use Plug.Router

  plug :match

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON

  plug :dispatch

  forward "/mcp",
    to: Phantom.Plug,
    init_opts: [
      router: MyApp.MCP.Router
    ]
end
```

<!-- tabs-close -->

See `Phantom.Plug` for its options and for local testing instructions.

### Stdio (local clients)

For local-only clients like Claude Desktop, you can expose your MCP server
over stdin/stdout without an HTTP server. Add `Phantom.Stdio` to your
supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  {Phantom.Stdio, router: MyApp.MCP.Router}
]
```

See `Phantom.Stdio` for building an escript for direct stdio clients.

## Try it

Make sure you test your server with the
[MCP Inspector](https://modelcontextprotocol.io/docs/tools/inspector) or your
client of choice, and with `Phantom.Test` in your test suite (see the
[Testing](testing.md) guide).

## Next steps

- [Tools](tools.md), [Prompts](prompts.md), and [Resources](resources.md):
  what your server offers, answered synchronously or asynchronously.
- [Authentication](authentication.md): implement `c:Phantom.Router.connect/2`
  and return `{:ok, session}` upon success.
- [Elicitation](elicitation.md): ask the user for input mid-request.
- [Deployment](deployment.md): load balancers, clustering, and tracing.

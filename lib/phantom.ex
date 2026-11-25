defmodule Phantom do
  @moduledoc """
  MCP (Model Context Protocol) framework for Elixir Plug.

  Start with the [Getting Started](getting_started.md) guide. The main
  modules are:

  - `Phantom.Router` declares your tools, prompts, resources, skills, and
    agents, and authenticates each request in `c:Phantom.Router.connect/2`.
  - `Phantom.Plug` serves the router over Streamable HTTP.
  - `Phantom.Stdio` serves the router over stdin and stdout.
  - `Phantom.Session` carries the client's state to your handlers.
  - `Phantom.Tool`, `Phantom.Prompt`, and `Phantom.Resource` build responses.
  - `Phantom.Tracker` routes sessions and notifications across a cluster.
  - `Phantom.Test` tests your handlers without HTTP.

  ## Extensions

  - `Phantom.Tasks` answers a tool call with a task the client polls. See the
    [Tasks](tasks.md) guide.
  - `Phantom.Skill` serves Agent Skills. See the [Skills](skills.md) guide.
  - `Phantom.App` and `Phantom.UI` deliver interactive HTML interfaces. See
    the [MCP Apps](mcp_apps.md) guide.
  - Machine clients authenticate with the `client_credentials` grant. See the
    [OAuth Client Credentials](oauth_client_credentials.md) guide.

  ## A2A

  The same router can serve [A2A](https://a2a-protocol.org) agents, sharing
  `c:Phantom.Router.connect/2`. See the [A2A](a2a.md) guide.

  - `Phantom.A2A.Agent` implements an agent.
  - `Phantom.A2A.Plug` serves agents over JSON-RPC and HTTP+JSON.
  - `Phantom.A2A.Bridge` serves your MCP tools as an agent.
  - `Phantom.A2A.Client` calls other agents.
  """
end

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
  """
end

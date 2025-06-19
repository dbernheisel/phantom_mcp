defmodule Test.Router do
  use Phoenix.Router, helpers: false
  import Plug.Conn

  pipeline :mcp do
    plug :accepts, ["json", "sse"]
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", Phantom.Plug,
      router: Test.MCP.Router,
      pubsub: Test.PubSub,
      validate_origin: false
  end
end

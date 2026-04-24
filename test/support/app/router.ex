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

  forward "/mcp-apps", Phantom.App.Preview,
    router: Test.MCP.Router,
    mcp_endpoint: "/mcp"

  get "/*path", Test.FallbackPlug, :index
end

defmodule Test.FallbackPlug do
  use Plug.Builder
  import Plug.Conn

  def init(_), do: []

  def call(conn, _opts) do
    conn |> send_resp(404, "Not found") |> halt()
  end
end

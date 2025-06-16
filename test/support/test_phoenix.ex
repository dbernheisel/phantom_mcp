defmodule Test.PhxEndpoint do
  use Phoenix.Endpoint, otp_app: :phantom

  @session_options [
    store: :cookie,
    key: "_foo_key",
    signing_salt: "JJahSh8C",
    same_site: "Lax"
  ]

  if Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.Session, @session_options

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON

  plug Test.PhxRouter
end

defmodule Test.PhxErrorJSON do
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end

defmodule Test.PhxRouter do
  use Phoenix.Router, helpers: false
  import Plug.Conn
  import Phoenix.LiveDashboard.Router

  Code.ensure_compiled!(Test.MCPRouter)

  pipeline :mcp do
    plug :accepts, ["json", "sse"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
  end

  scope "/" do
    pipe_through :browser
    live_dashboard "/dashboard"
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", Phantom.Plug,
      router: Test.MCPRouter,
      pubsub: Test.PubSub,
      validate_origin: false
  end
end

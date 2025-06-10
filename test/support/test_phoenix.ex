defmodule Test.PhxEndpoint do
  use Phoenix.Endpoint, otp_app: :phantom

  if Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

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

  Code.ensure_compiled!(Test.MCPRouter)

  pipeline :mcp do
    plug :accepts, ["json"]
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", Phantom.Plug,
      port: 5000,
      router: Test.MCPRouter,
      validate_origin: false
  end
end

defmodule Test.Endpoint do
  use Phoenix.Endpoint, otp_app: :phantom_mcp

  if Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON

  plug Test.Router
end

defmodule Test.ErrorJSON do
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end

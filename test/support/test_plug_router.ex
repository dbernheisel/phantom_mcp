defmodule Test.PlugRouter do
  use Plug.Router

  Code.ensure_compiled!(Test.MCPRouter)

  plug :match

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON

  plug :dispatch

  forward "/mcp",
    to: Phantom.Plug,
    init_opts: [port: 4000, validate_origin: false, router: Test.MCPRouter]

  match _ do
    send_resp(conn, "Not found", 404)
  end
end

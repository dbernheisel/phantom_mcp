defmodule Test.PlugRouter do
  use Plug.Router

  plug :match

  if Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON

  plug :dispatch

  forward "/mcp",
    to: Phantom.Plug,
    init_opts: [
      validate_origin: false,
      pubsub: Test.PubSub,
      router: Test.MCP.Router
    ]

  match _ do
    send_resp(conn, 404, "Not found")
  end
end

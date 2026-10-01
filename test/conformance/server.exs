# Serves Conformance.MCP.Router for the official MCP conformance suite.
# See test/conformance/README.md.
#
#     MIX_ENV=test mix run test/conformance/server.exs
#
# Environment variables:
#
# - `PORT` - port to listen on (default: 3999)
# - `VALIDATE_ORIGIN` - set to "true" to enable Origin validation (default:
#   "false"). The conformance client sends no Origin header, which Phantom
#   rejects when validation is enabled.

Code.require_file("router.ex", __DIR__)

defmodule Conformance.Plug do
  use Plug.Router

  @port String.to_integer(System.get_env("PORT", "3999"))

  plug :match

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON

  plug :dispatch

  forward "/mcp",
    to: Phantom.Plug,
    init_opts: [
      router: Conformance.MCP.Router,
      pubsub: Conformance.PubSub,
      validate_origin: System.get_env("VALIDATE_ORIGIN", "false") == "true",
      origins: ["http://localhost:#{@port}", "http://127.0.0.1:#{@port}"]
    ]
end

port = String.to_integer(System.get_env("PORT", "3999"))

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: Conformance.PubSub},
      {Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Conformance.PubSub]},
      {Bandit, plug: Conformance.Plug, ip: {127, 0, 0, 1}, port: port}
    ],
    strategy: :one_for_one
  )

IO.puts("Conformance server listening on http://localhost:#{port}/mcp")

# The supervisor is linked to this script process, so keep it alive.
Process.sleep(:infinity)

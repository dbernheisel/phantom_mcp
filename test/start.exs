#!/usr/bin/env elixir
Application.put_env(:phoenix, :json_library, JSON)
Application.put_env(:phoenix, :plug_init_mode, :runtime)
Application.put_env(:phantom_mcp, :timeout, 1000)

Application.put_env(:mime, :types, %{
  "text/event-stream" => ["sse"]
})

Application.put_env(:phantom_mcp, Test.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: Test.ErrorJSON],
    layout: false
  ],
  pubsub_server: Test.PubSub,
  code_reloader: true,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  secret_key_base: String.duplicate("a", 64)
)

Mix.install([
  {:plug_cowboy, "~> 2.7"},
  {:bandit, "~> 1.7"},
  {:phoenix, "~> 1.7"},
  {:phantom_mcp, path: "."}
])

Enum.each(
  ~w[
  test/support/app/mcp/router.ex
  test/support/app/router.ex
  test/support/app/endpoint.ex
  test/support/app/plug_router.ex
],
  &Code.require_file(&1, File.cwd!())
)

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: Test.PubSub},
      {Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]},
      {Plug.Cowboy, scheme: :http, plug: Test.PlugRouter, port: 4001},
      Test.Endpoint
    ],
    strategy: :one_for_one
  )

Process.sleep(:infinity)

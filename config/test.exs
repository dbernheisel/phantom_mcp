import Config

config :phantom, Test.PhxEndpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: Test.PhxErrorJSON],
    layout: false
  ],
  pubsub_server: Test.PubSub,
  code_reloader: config_env() == :dev,
  http: [ip: {127, 0, 0, 1}, port: 5000],
  server: true,
  secret_key_base: String.duplicate("a", 64)

config :phoenix, :json_library, JSON

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :mime, :types, %{
  "text/event-stream" => [],
  "text/streamable-http" => []
}

import Config

# `start.exs` (local verification, dev env) serves the preview through the real
# Phoenix router's `plug :accepts, ["json", "sse"]`, which needs MIME to know the
# "sse" extension. MIME resolves its type table at compile time, so a runtime
# Application.put_env(:mime, ...) is ignored — it must be set here. Tests drive
# Phantom.Plug directly and don't need it; consumers register their own.
if config_env() == :dev do
  config :mime, :types, %{"text/event-stream" => ["sse"]}
end

# The test app's slow tools wait `:timeout` milliseconds (`start.exs` sets the
# same value at runtime). The stdio escript is compiled in this environment, so
# it needs it at compile time.
if config_env() == :stdio do
  config :phantom_mcp, timeout: 1000
end

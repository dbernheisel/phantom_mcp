import Config

# `start.exs` (local verification, dev env) serves the preview through the real
# Phoenix router's `plug :accepts, ["json", "sse"]`, which needs MIME to know the
# "sse" extension. MIME resolves its type table at compile time, so a runtime
# Application.put_env(:mime, ...) is ignored — it must be set here. Tests drive
# Phantom.Plug directly and don't need it; consumers register their own.
if config_env() == :dev do
  config :mime, :types, %{"text/event-stream" => ["sse"]}
end

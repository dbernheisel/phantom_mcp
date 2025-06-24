#!/usr/bin/env iex
Application.put_env(:phoenix, :json_library, JSON)
Application.put_env(:phoenix, :plug_init_mode, :runtime)
Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)

Application.put_env(:phantom_mcp, :timeout, 1000)
Application.put_env(:phantom_mcp, :debug, true)

Application.put_env(:phantom_mcp, Test.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [sse: Test.ErrorJSON, json: Test.ErrorJSON],
    layout: false
  ],
  pubsub_server: Test.PubSub,
  code_reloader: true,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  secret_key_base: String.duplicate("a", 64)
)

Mix.install(
  [
    {:plug_cowboy, "~> 2.7"},
    {:bandit, "~> 1.7"},
    {:tidewave, "~> 0.1.9"},
    {:phoenix, "~> 1.7"},
    {:phantom_mcp, path: "."}
  ],
  config: [
    mime: [
      types: %{
        "text/event-stream" => ["sse"]
      }
    ]
  ]
)

Enum.each(
  ~w[
  test/support/app/mcp/router.ex
  test/support/app/router.ex
  test/support/app/endpoint.ex
  test/support/app/plug_router.ex
],
  &Code.require_file(&1, File.cwd!())
)

defmodule SessionChecker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(state) do
    Process.send_after(self(), :check, 5000)
    {:ok, state}
  end

  @sessions "phantom:sessions"
  @requests "phantom:requests"
  def handle_info(:check, state) do
    case Phantom.Tracker.list_sessions() do
      [] ->
        :ok

      sessions ->
        sessions
        |> Enum.map(fn {session_id, meta} ->
          pid = Phantom.Tracker.get_by_key(@sessions, session_id)
          {session_id, pid, Process.alive?(pid), meta}
        end)
        |> IO.inspect(label: "SESSIONS")
    end

    case Phantom.Tracker.list_requests() do
      [] ->
        :ok

      requests ->
        requests
        |> Enum.map(fn {request_id, _} ->
          pid = Phantom.Tracker.get_by_key(@requests, request_id)
          {request_id, pid, Process.alive?(pid)}
        end)
        |> IO.inspect(label: "REQUESTS")
    end

    Process.send_after(self(), :check, 10_000)
    {:noreply, state}
  end
end

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: Test.PubSub},
      {Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]},
      {Plug.Cowboy, scheme: :http, plug: Test.PlugRouter, port: 4001},
      Test.Endpoint,
      SessionChecker
    ],
    strategy: :one_for_one
  )

IEx.Server.run(env: __ENV__, binding: binding(), register: false)

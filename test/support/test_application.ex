defmodule Test.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Test.PubSub},
      {Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]},
      Test.PhxEndpoint,
      {Plug.Cowboy, scheme: :http, plug: Test.PlugRouter, port: 4000}
    ]

    opts = [strategy: :one_for_one, name: Test.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Test.PhxEndpoint.config_change(changed, removed)
    :ok
  end
end

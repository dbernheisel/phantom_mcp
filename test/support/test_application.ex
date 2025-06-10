defmodule Test.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Test.PubSub},
      Test.PhxEndpoint,
      {Bandit, port: 4000, ip: {127, 0, 0, 1}, plug: Test.PlugRouter}
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

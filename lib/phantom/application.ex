defmodule Phantom.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    :ok = Phantom.A2A.Push.start_profile()

    Supervisor.start_link(
      [
        Phantom.SessionMeta,
        {Registry, keys: :unique, name: Phantom.A2A.PushRegistry},
        {Task.Supervisor, name: Phantom.A2A.PushTasks},
        {DynamicSupervisor, name: Phantom.A2A.PushSupervisor, max_children: 10_000}
      ],
      strategy: :one_for_one,
      name: Phantom.Supervisor
    )
  end
end

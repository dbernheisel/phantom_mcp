defmodule Phantom.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([Phantom.SessionMeta],
      strategy: :one_for_one,
      name: Phantom.Supervisor
    )
  end
end

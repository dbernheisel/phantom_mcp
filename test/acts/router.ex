defmodule Phantom.ACTS.Router do
  @moduledoc false

  use Phantom.Router,
    name: "Phantom ACTS",
    vsn: "1.0",
    a2a: [well_known: "acts", allow_private_push_urls: true]

  agent "acts", Phantom.ACTS.Agent

  # A2A puts the extended card behind authentication, even when nothing else is.
  def connect(session, conn) do
    case conn.body_params do
      %{"method" => "GetExtendedAgentCard"} -> Phantom.ACTS.AuthRouter.connect(session, conn)
      _ -> {:ok, session}
    end
  end
end

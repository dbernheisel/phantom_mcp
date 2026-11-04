defmodule Phantom.ACTS.AuthRouter do
  @moduledoc """
  The ACTS agent behind bearer authentication: the suite's `ITK_ACTS_AUTH`
  agent. Its card stays public.
  """

  use Phantom.Router,
    name: "Phantom ACTS",
    vsn: "1.0",
    a2a: [
      well_known: "acts",
      allow_private_push_urls: true,
      security_schemes: %{"bearer" => %{"httpAuthSecurityScheme" => %{"scheme" => "Bearer"}}},
      security_requirements: [%{"schemes" => %{"bearer" => %{"list" => []}}}]
    ]

  agent "acts", Phantom.ACTS.Agent

  def connect(session, %Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer itk-valid-token"] -> {:ok, session}
      ["Bearer itk-insufficient-token"] -> {:forbidden, "Insufficient credentials"}
      _ -> {:unauthorized, %{method: "Bearer", realm: "acts"}}
    end
  end
end

defmodule Phantom.ACTS.HTTP do
  @moduledoc """
  Serves the ACTS agent's card at `/.well-known/agent-card.json` and the agent
  at `/a2a/acts`. Without `:pubsub`, the agent doesn't stream: that is the
  suite's reduced-capabilities agent.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    %{
      a2a:
        Phantom.A2A.Plug.init(
          router: Keyword.get(opts, :router, Phantom.ACTS.Router),
          pubsub: opts[:pubsub],
          mount: "/a2a",
          validate_origin: false
        )
    }
  end

  @impl Plug
  def call(conn, opts) do
    case conn.path_info do
      [".well-known", "agent-card.json"] ->
        Phantom.A2A.Plug.call(conn, opts.a2a)

      ["a2a" | rest] ->
        Phantom.A2A.Plug.call(%{conn | path_info: rest, script_name: ["a2a"]}, opts.a2a)

      _ ->
        send_resp(conn, 404, "")
    end
  end
end

defmodule Phantom.Test.ClusterPlug do
  @moduledoc false

  use Plug.Builder

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON

  plug :phantom

  defp phantom(conn, _opts) do
    Phantom.Plug.call(conn, conn.private.phantom_opts)
  end

  @impl true
  def init(opts) do
    phantom_opts = Phantom.Plug.init(Keyword.fetch!(opts, :phantom_opts))
    Keyword.put(opts, :phantom_opts, phantom_opts)
  end

  @impl true
  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:phantom_opts, opts[:phantom_opts])
    |> super(opts)
  end
end

defmodule Phantom.Test.Conformance do
  @moduledoc """
  Runs the official MCP conformance suite against `Conformance.MCP.Router`.

  The router is served by the peer nodes that `Phantom.Test.Cluster` starts.
  The `:single` topology points the suite at one node. The `:distributed`
  topology points it at `Phantom.Test.ConformanceProxy`, which alternates
  every request between the nodes.
  """

  @nodes [{:"node1@127.0.0.1", 4111}, {:"node2@127.0.0.1", 4112}]
  @proxy_port 4110
  @baselines Path.expand("../conformance/expected-failures", __DIR__)

  @doc "Serve the conformance router on every peer node and start the proxy."
  def start do
    for {node, port} <- @nodes, do: start_backend(node, port)

    backends = for {_node, port} <- @nodes, do: "http://127.0.0.1:#{port}"

    {:ok, _} =
      Bandit.start_link(
        plug: {Phantom.Test.ConformanceProxy, backends: backends},
        ip: {127, 0, 0, 1},
        port: @proxy_port,
        startup_log: false
      )

    :ok
  end

  @doc "The MCP endpoint for a topology."
  def url(:single), do: "http://127.0.0.1:#{@nodes |> hd() |> elem(1)}/mcp"
  def url(:distributed), do: "http://127.0.0.1:#{@proxy_port}/mcp"

  @doc """
  Run every scenario a spec revision requires, checked against that
  revision's expected-failures baseline plus the topology's additions, if
  any. Returns `{exit_status, output}`.
  """
  def run(topology, revision) do
    System.cmd(
      "npx",
      [
        "conformance",
        "server",
        "--url",
        url(topology),
        "--requirements",
        revision,
        "--expected-failures",
        baseline(topology, revision),
        "--timeout",
        "15000"
      ],
      stderr_to_stdout: true,
      env: [{"NO_COLOR", "1"}, {"FORCE_COLOR", "0"}]
    )
    |> then(fn {output, status} -> {status, output} end)
  end

  # The CLI takes one baseline file, so the topology's additions are appended
  # to the revision's entries in a temporary copy.
  defp baseline(topology, revision) do
    entries =
      for file <- ["#{revision}.yml", "#{revision}.#{topology}.yml"],
          path = Path.join(@baselines, file),
          File.exists?(path),
          line <- File.stream!(path),
          String.match?(line, ~r/^\s+- /),
          do: line

    path = Path.join(System.tmp_dir!(), "phantom-conformance-#{topology}-#{revision}.yml")
    File.write!(path, ["server:\n" | entries])
    path
  end

  defp start_backend(node, port) do
    :rpc.block_call(node, Phantom.Cache, :register, [Conformance.MCP.Router])

    plug_opts = [
      router: Conformance.MCP.Router,
      pubsub: Phantom.Test.PubSub,
      validate_origin: false
    ]

    {:ok, _} =
      :rpc.block_call(node, Bandit, :start_link, [
        [
          plug: {Phantom.Test.ClusterPlug, phantom_opts: plug_opts},
          ip: {127, 0, 0, 1},
          port: port,
          startup_log: false
        ]
      ])
  end
end

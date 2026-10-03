# Serves Conformance.MCP.Router for the official MCP conformance suite.
# See test/conformance/README.md.
#
#     MIX_ENV=test mix run test/conformance/server.exs
#
# Starts the same two-node cluster that `mix test --only conformance` uses and
# prints the URL of each topology.

Phantom.Test.Cluster.spawn([
  {:"node1@127.0.0.1", port: 4101},
  {:"node2@127.0.0.1", port: 4102}
])

:ok = Phantom.Test.Conformance.start()

for topology <- [:single, :distributed] do
  IO.puts("Conformance server listening (#{topology}): #{Phantom.Test.Conformance.url(topology)}")
end

Process.sleep(:infinity)

exclude = Keyword.get(ExUnit.configuration(), :exclude, [])

unless :clustered in exclude do
  Phantom.Test.Cluster.spawn([
    {:"node1@127.0.0.1", port: 4101},
    {:"node2@127.0.0.1", port: 4102}
  ])
end

ExUnit.start()

exclude = Keyword.get(ExUnit.configuration(), :exclude, [])

unless :clustered in exclude do
  # epmd only starts on its own when the VM boots with --name/--sname
  with {:error, _} <- :erl_epmd.names() do
    {_, 0} = System.cmd("epmd", ["-daemon"])
  end

  Phantom.Test.Cluster.spawn([
    {:"node1@127.0.0.1", port: 4101},
    {:"node2@127.0.0.1", port: 4102}
  ])
end

ExUnit.start(exclude: [:conformance | exclude])

defmodule Phantom.Test.Cluster do
  @moduledoc """
  A helper module for testing distributed Phantom MCP across multiple nodes.

  Spawns peer nodes via `:peer.start/1`, copies code paths and config,
  then starts PubSub, Phantom.Tracker, and a Bandit HTTP server on each.

  Requires `epmd` to be running: `epmd -daemon`
  """

  def spawn(nodes) do
    :net_kernel.start([:"primary@127.0.0.1"])

    nodes
    |> Enum.map(&Task.async(fn -> spawn_node(&1) end))
    |> Enum.map(&Task.await(&1, 30_000))
  end

  defp spawn_node({node_host, opts}) do
    cookie = :erlang.get_cookie()

    {:ok, _peer, node} =
      :peer.start(%{
        name: node_name(node_host),
        host: ~c"127.0.0.1",
        env: [{~c"ERL_AFLAGS", ~c"-setcookie #{cookie}"}]
      })

    true = Node.connect(node)
    add_code_paths(node)
    transfer_configuration(node)
    ensure_applications_started(node)
    start_services(node, opts)
    {:ok, node}
  end

  defp spawn_node(node_host), do: spawn_node({node_host, []})

  defp rpc(node, module, function, args) do
    :rpc.block_call(node, module, function, args)
  end

  defp add_code_paths(node) do
    rpc(node, :code, :add_paths, [:code.get_path()])
  end

  defp transfer_configuration(node) do
    for {app_name, _, _} <- Application.loaded_applications() do
      for {key, val} <- Application.get_all_env(app_name) do
        rpc(node, Application, :put_env, [app_name, key, val])
      end
    end
  end

  defp ensure_applications_started(node) do
    rpc(node, Application, :ensure_all_started, [:mix])
    rpc(node, Mix, :env, [Mix.env()])

    for {app_name, _, _} <- Application.loaded_applications() do
      rpc(node, Application, :ensure_all_started, [app_name])
    end
  end

  defp start_services(node, opts) do
    port = Keyword.fetch!(opts, :port)
    pubsub_name = Keyword.get(opts, :pubsub, Test.PubSub)

    rpc(node, Phantom.Cache, :register, [Test.MCP.Router])

    plug_opts =
      Phantom.Plug.init(
        router: Test.MCP.Router,
        pubsub: pubsub_name,
        validate_origin: false
      )

    rpc(node, Supervisor, :start_link, [
      [
        {Phoenix.PubSub, name: pubsub_name},
        {Phantom.Tracker, name: Phantom.Tracker, pubsub_server: pubsub_name},
        {Bandit, plug: {Phantom.Plug, plug_opts}, port: port, scheme: :http}
      ],
      [strategy: :one_for_one, name: :"phantom_test_sup_#{port}"]
    ])
  end

  defp node_name(node_host) do
    node_host
    |> to_string()
    |> String.split("@")
    |> Enum.at(0)
    |> String.to_atom()
  end
end

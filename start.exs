#!/usr/bin/env iex
Application.put_env(:phoenix, :json_library, JSON)
Application.put_env(:phoenix, :plug_init_mode, :runtime)
Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)

Application.put_env(:phantom_mcp, :timeout, 1000)
Application.put_env(:phantom_mcp, :debug, true)

Application.put_env(:phantom_mcp, Test.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [sse: Test.ErrorJSON, json: Test.ErrorJSON],
    layout: false
  ],
  pubsub_server: Test.PubSub,
  code_reloader: true,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  secret_key_base: String.duplicate("a", 64)
)

Mix.install(
  [
    {:plug_cowboy, "~> 2.7"},
    {:bandit, "~> 1.7"},
    {:tidewave, "~> 0.1.9"},
    {:phoenix, "~> 1.7"},
    {:phantom_mcp, path: "."}
  ],
  config: [
    mime: [
      types: %{
        "text/event-stream" => ["sse"]
      }
    ]
  ]
)

Enum.each(
  ~w[
  test/support/app/mcp/router.ex
  test/support/app/router.ex
  test/support/app/endpoint.ex
  test/support/app/plug_router.ex
  test/support/cluster_plug.ex
],
  &Code.require_file(&1, File.cwd!())
)

defmodule SessionChecker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(state) do
    Process.send_after(self(), :check, 5000)
    {:ok, state}
  end

  def handle_info(:check, state) do
    case Phantom.Tracker.list_sessions() do
      [] ->
        :ok

      sessions ->
        sessions
        |> Enum.flat_map(fn {session_id, meta} ->
          if pid = Phantom.Tracker.get_session(session_id) do
            [{session_id, pid, meta}]
          else
            []
          end
        end)
        |> tap(&if &1 != [], do: IO.inspect(&1, label: "SESSIONS"))
    end

    case Phantom.Tracker.list_requests() do
      [] ->
        :ok

      requests ->
        requests
        |> Enum.flat_map(fn {request_id, meta} ->
          if pid = Phantom.Tracker.get_request(request_id) do
            [{request_id, pid, meta}]
          else
            []
          end
        end)
        |> tap(&if &1 != [], do: IO.inspect(&1, label: "REQUESTS"))
    end

    case Phantom.Tracker.list_resource_listeners() do
      [] ->
        :ok

      uris ->
        uris
        |> Enum.map(fn {uri, _meta} -> uri end)
        |> IO.inspect(label: "RESOURCE SUBSCRIPTIONS")
    end

    Process.send_after(self(), :check, 10_000)
    {:noreply, state}
  end
end

defmodule LoadBalancer do
  use Plug.Builder
  require Logger

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON

  plug :balance

  defp balance(conn, _opts) do
    {backends, counter} = :persistent_term.get(:lb_config)
    idx = :atomics.add_get(counter, 1, 1)
    backend = Enum.at(backends, rem(idx, length(backends)))
    proxy(conn, backend)
  end

  defp proxy(conn, port) do
    method = conn.method |> String.downcase() |> String.to_atom()
    url = "http://127.0.0.1:#{port}#{conn.request_path}"

    headers =
      conn.req_headers
      |> Enum.reject(fn {k, _} -> k in ~w[host content-length transfer-encoding] end)

    body =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> nil
        params when map_size(params) == 0 -> nil
        params -> JSON.encode!(params)
      end

    req_opts =
      [url: url, method: method, headers: headers]
      |> then(fn opts -> if body, do: Keyword.put(opts, :body, body), else: opts end)

    resp = Req.request!(Req.new(req_opts ++ [into: :self, receive_timeout: 300_000]))

    Logger.info("LB #{conn.method} → :#{port} (#{resp.status})")

    conn =
      Enum.reduce(resp.headers, conn, fn {key, values}, acc ->
        Enum.reduce(List.wrap(values), acc, fn val, acc2 ->
          Plug.Conn.put_resp_header(acc2, key, val)
        end)
      end)

    case resp.status do
      status when status in [200, 202] and is_struct(resp.body, Req.Response.Async) ->
        # SSE stream — pipe chunks through
        conn = Plug.Conn.send_chunked(conn, status)
        stream_proxy(conn, resp.body.ref)

      status ->
        # Non-streaming response
        body = if is_binary(resp.body), do: resp.body, else: ""
        Plug.Conn.send_resp(conn, status, body)
    end
  end

  defp stream_proxy(conn, ref) do
    receive do
      {^ref, {:data, chunk}} ->
        case Plug.Conn.chunk(conn, chunk) do
          {:ok, conn} -> stream_proxy(conn, ref)
          {:error, _} -> conn
        end

      {^ref, :done} ->
        conn
    after
      300_000 -> conn
    end
  end

  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)
    backends = Keyword.fetch!(opts, :backends)
    counter = :atomics.new(1, [])
    :persistent_term.put(:lb_config, {backends, counter})

    %{
      id: __MODULE__,
      start: {Bandit, :start_link, [[plug: __MODULE__, port: port, scheme: :http]]},
      type: :supervisor
    }
  end
end

defmodule PeerNode do
  def spawn!(port) do
    cookie = :erlang.get_cookie()

    {:ok, _peer, node} =
      :peer.start(%{
        name: :"peer_#{port}",
        host: ~c"127.0.0.1",
        env: [{~c"ERL_AFLAGS", ~c"-setcookie #{cookie}"}]
      })

    true = Node.connect(node)
    :rpc.block_call(node, :code, :add_paths, [:code.get_path()])

    for {app_name, _, _} <- Application.loaded_applications() do
      for {key, val} <- Application.get_all_env(app_name) do
        :rpc.block_call(node, Application, :put_env, [app_name, key, val])
      end
    end

    :rpc.block_call(node, Application, :ensure_all_started, [:mix])

    for {app_name, _, _} <- Application.loaded_applications() do
      :rpc.block_call(node, Application, :ensure_all_started, [app_name])
    end

    # Modules loaded via Code.require_file on primary exist only in memory.
    # Load the source files on the peer node too.
    cwd = File.cwd!()

    for file <- ~w[
          test/support/app/mcp/router.ex
          test/support/app/router.ex
          test/support/app/endpoint.ex
          test/support/app/plug_router.ex
          test/support/cluster_plug.ex
        ] do
      :rpc.block_call(node, Code, :require_file, [file, cwd])
    end

    :rpc.block_call(node, Phantom.Cache, :register, [Test.MCP.Router])

    plug_opts = [
      router: Test.MCP.Router,
      pubsub: Test.PubSub,
      validate_origin: false
    ]

    {:ok, _} =
      :rpc.block_call(node, Supervisor, :start_link, [
        [
          {Phoenix.PubSub, name: Test.PubSub},
          {Phantom.Tracker, name: Phantom.Tracker, pubsub_server: Test.PubSub},
          {Bandit,
           plug: {Phantom.Test.ClusterPlug, phantom_opts: plug_opts}, port: port, scheme: :http}
        ],
        [strategy: :one_for_one, name: :"phantom_peer_sup_#{port}"]
      ])

    node
  end
end

:net_kernel.start([:"primary@127.0.0.1"])

plug_opts = [router: Test.MCP.Router, pubsub: Test.PubSub, validate_origin: false]

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: Test.PubSub},
      {Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]},
      {Bandit,
       plug: {Phantom.Test.ClusterPlug, phantom_opts: plug_opts},
       port: 4002,
       scheme: :http,
       startup_log: false},
      SessionChecker
    ],
    strategy: :one_for_one
  )

peer = PeerNode.spawn!(4003)

{:ok, _lb} =
  Supervisor.start_link(
    [{LoadBalancer, port: 4000, backends: [4002, 4003]}],
    strategy: :one_for_one,
    name: :lb_sup
  )

IO.puts("""

  Load Balancer:  http://localhost:4000/mcp (round-robin)
  Primary node:   http://localhost:4002/mcp (#{node()})
  Peer node:      http://localhost:4003/mcp (#{peer})
""")

IEx.Server.run(env: __ENV__, binding: binding(), register: false)

defmodule Phantom.SessionInactivityHTTPTest.Router do
  use Phantom.Router, name: "InactivityTest", vsn: "1.0"

  require Phantom.Tool

  tool :controlled, description: "Waits for the test to release the result" do
  end

  def connect(session, conn) do
    {:ok, %{session | assigns: %{observer: conn.assigns.observer}}}
  end

  def controlled(_params, session) do
    send(session.assigns.observer, {:started, session.request.id, self(), session.pid})

    receive do
      :complete ->
        :ok

      :progress ->
        Phantom.Session.notify_progress(session, 1, 2, "working")

        receive do
          :complete -> :ok
        end
    end

    {:reply, Phantom.Tool.text("done"), session}
  end
end

defmodule Phantom.SessionInactivityHTTPTest.Plug do
  alias Phantom.SessionInactivityHTTPTest.Router

  def init(opts), do: opts

  def call(conn, opts) do
    parser = Plug.Parsers.init(parsers: [:json], json_decoder: JSON)

    phantom =
      Phantom.Plug.init(
        router: Router,
        session_timeout: opts[:timeout],
        listener: opts[:observer]
      )

    conn
    |> Plug.Conn.assign(:observer, opts[:observer])
    |> Plug.Parsers.call(parser)
    |> Phantom.Plug.call(phantom)
  end
end

defmodule Phantom.SessionInactivityHTTPTest do
  use ExUnit.Case, async: true

  alias Phantom.SessionInactivityHTTPTest.Plug

  @timeout to_timeout(second: 30)
  @wait to_timeout(second: 3)

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: {Plug, observer: self(), timeout: @timeout},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @wait)
    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, socket: socket}
  end

  for version <- ["2026-07-28", "2025-06-18"] do
    @version version
    test "a later request on the same connection ignores old timeouts (#{version})", %{
      socket: socket
    } do
      post(socket, 1, @version)
      assert_receive {:started, 1, worker_a, transport_a}, @wait
      before = :sys.get_state(transport_a)
      send(worker_a, :complete)
      assert response(socket) =~ "\"result\""

      post(socket, 2, @version)
      assert_receive {:started, 2, worker_b, transport_b}, @wait
      assert transport_a == transport_b
      assert Process.read_timer(before.timer) == false

      send(transport_b, {:timeout, before.timer, :inactivity})
      send(transport_b, :inactivity)
      state = :sys.get_state(transport_b)
      assert is_integer(Process.read_timer(state.timer))
      send(worker_b, :complete)

      result = response(socket)
      assert result =~ "\"id\":2"
      assert result =~ "\"result\""
      refute result =~ "inactivity"
    end
  end

  test "progress protects the result from a queued old timeout", %{socket: socket} do
    post(socket, 1, "2026-07-28")
    assert_receive {:started, 1, worker, transport}, @wait
    before = :sys.get_state(transport)
    send(worker, :progress)
    assert_receive {:response, nil, "message", %{method: "notifications/progress"}}, @wait
    send(transport, {:timeout, before.timer, :inactivity})
    state = :sys.get_state(transport)
    assert state.timer != before.timer
    assert Process.read_timer(before.timer) == false
    send(worker, :complete)

    result = response(socket)
    assert result =~ "notifications/progress"
    assert result =~ "\"result\""
    refute result =~ "inactivity"
  end

  defp post(socket, id, version) do
    meta =
      if version == "2026-07-28" do
        %{
          "io.modelcontextprotocol/protocolVersion" => version,
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "progressToken" => "token"
        }
      else
        %{"protocolVersion" => version}
      end

    body =
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: id,
        method: "tools/call",
        params: %{name: "controlled", arguments: %{}, _meta: meta}
      })

    assert :ok =
             :gen_tcp.send(socket, [
               "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n",
               "Accept: application/json, text/event-stream\r\nMCP-Protocol-Version: ",
               version,
               "\r\nMCP-Method: tools/call\r\nMCP-Name: controlled\r\nContent-Length: ",
               Integer.to_string(byte_size(body)),
               "\r\n\r\n",
               body
             ])
  end

  defp response(socket, acc \\ "") do
    if String.ends_with?(acc, "0\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, @wait)
      response(socket, acc <> data)
    end
  end
end

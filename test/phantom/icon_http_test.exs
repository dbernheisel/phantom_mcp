defmodule Phantom.IconHTTPTest do
  @moduledoc """
  End-to-end HTTP test that boots a real Phoenix Endpoint and verifies
  icon payloads come through on the wire via initialize and tools/list.
  """
  use ExUnit.Case

  @port 4042

  setup_all do
    start_supervised({Phoenix.PubSub, name: Test.PubSub})
    start_supervised({Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]})
    Phantom.Cache.register(Test.MCP.Router)

    start_supervised(
      {Test.Endpoint,
       url: [host: "localhost"],
       adapter: Bandit.PhoenixAdapter,
       render_errors: [formats: [json: Test.ErrorJSON], layout: false],
       pubsub_server: Test.PubSub,
       http: [ip: {127, 0, 0, 1}, port: @port],
       server: true,
       secret_key_base: String.duplicate("a", 64)}
    )

    :ok
  end

  defp post_jsonrpc(body) do
    json = JSON.encode!(body)

    request =
      "POST /mcp HTTP/1.1\r\n" <>
        "Host: localhost:#{@port}\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Accept: application/json, text/event-stream\r\n" <>
        "Content-Length: #{byte_size(json)}\r\n" <>
        "Connection: close\r\n" <>
        "\r\n" <>
        json

    {:ok, socket} = :gen_tcp.connect(~c"localhost", @port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, request)

    response = recv_all(socket, "")
    :gen_tcp.close(socket)

    # Split headers from body, then parse SSE data from chunked body
    [_headers, body] = String.split(response, "\r\n\r\n", parts: 2)

    body
    |> String.split("\n")
    |> Enum.find_value(fn
      "data: " <> data -> JSON.decode!(data)
      _ -> nil
    end)
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, :timeout} -> acc
    end
  end

  test "initialize returns serverInfo with icons and websiteUrl from MFA" do
    response =
      post_jsonrpc(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-06-18",
          capabilities: %{},
          clientInfo: %{name: "HTTPTestClient", version: "1.0"}
        }
      })

    server_info = response["result"]["serverInfo"]

    assert server_info["name"] == "Test"
    assert server_info["version"] == "1.0"

    # website_url resolves {Test.Endpoint, :url, []} at runtime
    assert server_info["websiteUrl"] == "http://localhost:#{@port}"

    # icons resolve {Phoenix.VerifiedRoutes, :static_url, [Test.Endpoint, path]} at runtime
    assert [icon1, icon2] = server_info["icons"]

    assert icon1["src"] =~ "/images/test-icon.png"
    assert icon1["mimeType"] == "image/png"
    assert icon1["sizes"] == ["48x48"]

    assert icon2["src"] =~ "/images/test-icon-dark.svg"
    assert icon2["mimeType"] == "image/svg+xml"
    assert icon2["theme"] == "dark"
  end

  test "tools/list returns icons on tools that have them" do
    response =
      post_jsonrpc(%{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/list",
        params: %{}
      })

    tools = response["result"]["tools"]

    echo_tool = Enum.find(tools, &(&1["name"] == "echo_tool"))
    assert echo_tool, "echo_tool should be in the tools list"

    assert [%{"src" => "https://example.com/echo-icon.png", "mimeType" => "image/png"}] =
             echo_tool["icons"]

    # Tools without icons should NOT have the icons key
    binary_tool = Enum.find(tools, &(&1["name"] == "binary_tool"))
    assert binary_tool, "binary_tool should be in the tools list"
    refute Map.has_key?(binary_tool, "icons")
  end
end

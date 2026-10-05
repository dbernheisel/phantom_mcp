defmodule Phantom.SSEHeadersTest do
  @moduledoc """
  End-to-end HTTP test asserting SSE responses carry no connection-specific
  (hop-by-hop) headers. RFC 9113 §8.2.2 requires HTTP/2 clients to treat any
  response containing them as malformed, which makes an h2 MCP server
  unreachable.
  """
  use ExUnit.Case

  @port 4043

  # `transfer-encoding` is excluded: it is HTTP/1.1 framing written by the
  # adapter, not by Phantom, and is absent under HTTP/2.
  @hop_by_hop_headers ~w[connection keep-alive proxy-connection upgrade te]

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

  test "POST SSE response omits connection-specific headers" do
    json =
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-06-18",
          capabilities: %{},
          clientInfo: %{name: "SSEHeadersTestClient", version: "1.0"}
        }
      })

    headers =
      response_headers(
        "POST /mcp HTTP/1.1\r\n" <>
          "Host: localhost:#{@port}\r\n" <>
          "Content-Type: application/json\r\n" <>
          "Accept: application/json, text/event-stream\r\n" <>
          "Content-Length: #{byte_size(json)}\r\n" <>
          "\r\n" <>
          json
      )

    assert headers["content-type"] == "text/event-stream; charset=utf-8"
    assert headers["x-accel-buffering"] == "no"

    for header <- @hop_by_hop_headers do
      refute Map.has_key?(headers, header),
             "expected no #{header} header, got: #{inspect(headers[header])}"
    end
  end

  test "GET SSE response returns 200 OK" do
    {status, _headers} =
      response_status_and_headers(
        "GET /mcp HTTP/1.1\r\n" <>
          "Host: localhost:#{@port}\r\n" <>
          "Accept: application/json, text/event-stream\r\n" <>
          "\r\n"
      )

    assert status == 200
  end

  test "POST SSE events do not reuse JSON-RPC ids as event ids" do
    json = JSON.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"})

    body =
      response_body(
        "POST /mcp HTTP/1.1\r\n" <>
          "Host: localhost:#{@port}\r\n" <>
          "Content-Type: application/json\r\n" <>
          "Accept: application/json, text/event-stream\r\n" <>
          "Content-Length: #{byte_size(json)}\r\n" <>
          "\r\n" <>
          json
      )

    assert body =~ ~s|"result":{}|
    refute body =~ ~r/^id: 1$/m
  end

  test "GET SSE response omits connection-specific headers" do
    headers =
      response_headers(
        "GET /mcp HTTP/1.1\r\n" <>
          "Host: localhost:#{@port}\r\n" <>
          "Accept: application/json, text/event-stream\r\n" <>
          "\r\n"
      )

    assert headers["content-type"] == "text/event-stream; charset=utf-8"
    assert headers["x-accel-buffering"] == "no"

    for header <- @hop_by_hop_headers do
      refute Map.has_key?(headers, header),
             "expected no #{header} header, got: #{inspect(headers[header])}"
    end
  end

  defp response_headers(request) do
    {_status, headers} = response_status_and_headers(request)
    headers
  end

  defp response_status_and_headers(request) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", @port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, request)
    response = recv_until_headers(socket, "")
    :gen_tcp.close(socket)

    [headers, _body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(headers, "\r\n")
    [_version, status | _] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {String.to_integer(status), headers}
  end

  defp response_body(request) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", @port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, request)
    response = recv_until_closed(socket, "")
    :gen_tcp.close(socket)

    [_headers, body] = String.split(response, "\r\n\r\n", parts: 2)
    body
  end

  defp recv_until_closed(socket, acc) do
    if String.contains?(acc, "event: closed") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, data} -> recv_until_closed(socket, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  defp recv_until_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, data} -> recv_until_headers(socket, acc <> data)
        {:error, _} -> acc
      end
    end
  end
end

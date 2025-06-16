defmodule Phantom.PlugTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  doctest Phantom.Plug

  @opts Phantom.Plug.init(
          pubsub: Test.PubSub,
          router: Test.MCPRouter,
          validate_origin: false
        )
  @cors_opts Phantom.Plug.init(
               router: Test.MCPRouter,
               origins: ["http://localhost:4000"],
               validate_origin: true
             )

  @ping_message %{jsonrpc: "2.0", method: "ping", id: 1}

  setup do
    Phantom.Cache.register(Test.MCPRouter)
  end

  describe "plug initialization" do
    test "initializes with valid router" do
      opts = Phantom.Plug.init(router: Test.MCPRouter)
      assert opts[:router] == Test.MCPRouter
      assert opts[:validate_origin] == true
      assert opts[:origins] == ["http://localhost:4000"]
    end

    test "raises error with invalid router" do
      assert_raise ArgumentError, fn ->
        Phantom.Plug.init(router: InvalidRouter)
      end
    end
  end

  describe "CORS preflight requests" do
    test "handles valid preflight request" do
      :options
      |> conn("/mcp")
      |> put_req_header("origin", "http://localhost:4000")
      |> call(@cors_opts)

      assert_receive {:conn, conn}
      assert conn.status == 204

      assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:4000"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]

      allowed_headers =
        String.split(
          get_resp_header(conn, "access-control-allow-headers") |> List.first(),
          ", "
        )

      expose_headers =
        String.split(
          get_resp_header(conn, "access-control-expose-headers") |> List.first(),
          ", "
        )

      assert "content-type" in allowed_headers
      assert "authorization" in allowed_headers
      assert "mcp-session-id" in allowed_headers
      assert "last-event-id" in allowed_headers

      assert "mcp-session-id" in expose_headers
      assert "last-event-id" in expose_headers

      assert conn.halted
    end

    test "rejects preflight with invalid origin" do
      :options
      |> conn("/mcp")
      |> put_req_header("origin", "http://evil.example")
      |> call(@cors_opts)

      assert_receive {:conn, conn}
      assert conn.status == 403
      assert conn.halted

      error = conn.resp_body |> JSON.decode!()
      assert error["error"]["code"] == -32000
      assert error["error"]["message"] == "Origin not allowed"
    end
  end

  describe "CORS headers" do
    test "sets CORS headers for valid origin" do
      :post
      |> conn("/mcp", @ping_message)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://localhost:4000")
      |> call(@cors_opts)

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:4000"]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]

      allowed_headers =
        String.split(
          get_resp_header(conn, "access-control-allow-headers") |> List.first(),
          ", "
        )

      expose_headers =
        String.split(
          get_resp_header(conn, "access-control-expose-headers") |> List.first(),
          ", "
        )

      assert "content-type" in allowed_headers
      assert "authorization" in allowed_headers
      assert "mcp-session-id" in allowed_headers
      assert "last-event-id" in allowed_headers

      assert "mcp-session-id" in expose_headers
      assert "last-event-id" in expose_headers
    end

    test "does not set CORS headers for invalid origin" do
      :post
      |> conn("/mcp", @ping_message)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://evil.example")
      |> call(@cors_opts)

      assert_receive {:conn, conn}
      assert conn.status == 403
      headers = Enum.map(conn.resp_headers, &elem(&1, 0))

      for header <- ~w[access-control-expose-headers
        access-control-allow-origin
        access-control-allow-credentials
        access-control-allow-methods
        access-control-allow-headers
        access-control-max-age],
          do: assert(header not in headers)
    end
  end

  describe "origin validation" do
    test "allows all origins when validate_origin is false" do
      :post
      |> conn("/mcp", @ping_message)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://evil.example")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200
    end

    test "validates origin when enabled" do
      opts = Phantom.Plug.init(router: Test.MCPRouter, origins: :all, validate_origin: true)

      :post
      |> conn("/mcp", @ping_message)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "http://any-origin.example")
      |> call(opts)

      assert_receive {:conn, conn}
      assert conn.status == 200
    end
  end

  describe "content length validation" do
    test "rejects requests that exceed max_request_size" do
      opts =
        Phantom.Plug.init(validate_origin: false, router: Test.MCPRouter, max_request_size: 10)

      :post
      |> conn("/mcp", @ping_message)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("content-length", "100")
      |> call(opts)

      assert_receive {:conn, conn}
      assert conn.status == 413

      error = JSON.decode!(conn.resp_body)
      assert error["error"]["code"] == -32600
      assert error["error"]["message"] == "Request too large"
    end
  end

  describe "malformed requests" do
    test "handles missing body" do
      :post
      |> conn("/mcp")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 400
      error = JSON.decode!(conn.resp_body)

      assert error["error"]["code"] == -32700
      assert error["error"]["message"] == "Parse error: Invalid JSON"
    end
  end

  describe "SSE handling" do
    test "GET request returns error" do
      :get
      |> conn("/mcp")
      |> put_req_header("accept", "text/event-stream")
      |> call(Map.put(@opts, :pubsub, nil))

      assert_receive {:conn, conn}
      assert conn.status == 405
      error = JSON.decode!(conn.resp_body)

      assert error["error"]["code"] == -32601
      assert error["error"]["message"] == "SSE not supported"
    end

    test "GET request tracks connection in Tracker" do
      :get
      |> conn("/mcp")
      |> put_req_header("accept", "text/event-stream")
      |> call(@opts)

      assert_receive {:plug_conn, :sent}
      assert Phantom.Session.list() != []
    end
  end

  @parser Plug.Parsers.init(
            parsers: [{:json, length: 1_000_000}],
            pass: ["application/json"],
            json_decoder: JSON
          )
  defp call(conn, opts) do
    test_pid = self()

    :proc_lib.spawn_link(fn ->
      send(
        test_pid,
        {:conn,
         conn
         |> Plug.Parsers.call(@parser)
         |> Phantom.Plug.call(Map.put(opts, :listener, test_pid))}
      )
    end)
  end
end

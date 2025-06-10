defmodule Phantom.PlugTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  doctest Phantom.Plug

  @opts Phantom.Plug.init(
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
      conn =
        :options
        |> conn("/mcp")
        |> put_req_header("origin", "http://localhost:4000")
        |> call(@cors_opts)

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
      conn =
        :options
        |> conn("/mcp")
        |> put_req_header("origin", "http://evil.example")
        |> call(@cors_opts)

      assert conn.status == 403
      error = conn.resp_body |> JSON.decode!()
      assert error["error"]["code"] == -32600
      assert error["error"]["message"] == "Origin not allowed"
      assert conn.halted
    end
  end

  describe "CORS headers" do
    test "sets CORS headers for valid origin" do
      conn =
        :post
        |> conn("/mcp", @ping_message)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "http://localhost:4000")
        |> call(@cors_opts)

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
      conn =
        :post
        |> conn("/mcp", @ping_message)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "http://evil.example")
        |> call(@cors_opts)

      assert conn.status == 403
    end
  end

  describe "origin validation" do
    test "allows all origins when validate_origin is false" do
      conn =
        :post
        |> conn("/mcp", @ping_message)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "http://evil.example")
        |> call(@opts)

      assert conn.status == 200
    end

    test "validates origin when enabled" do
      opts = Phantom.Plug.init(router: Test.MCPRouter, origins: :all, validate_origin: true)

      conn =
        :post
        |> conn("/mcp", @ping_message)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "http://any-origin.example")
        |> call(opts)

      assert conn.status == 200
    end
  end

  describe "content length validation" do
    test "rejects requests that exceed max_request_size" do
      opts =
        Phantom.Plug.init(validate_origin: false, router: Test.MCPRouter, max_request_size: 10)

      conn =
        :post
        |> conn("/mcp", @ping_message)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-length", "100")
        |> call(opts)

      assert conn.status == 413
      error = conn.resp_body |> JSON.decode!()
      assert error["error"]["code"] == -32600
      assert error["error"]["message"] == "Request too large"
    end
  end

  describe "malformed requests" do
    test "handles missing body" do
      conn =
        :post
        |> conn("/mcp")
        |> call(@opts)

      assert conn.status == 400
      error = conn.resp_body |> JSON.decode!()
      assert error["error"]["code"] == -32700
      assert error["error"]["message"] == "Parse error: Invalid JSON"
    end
  end

  @parser Plug.Parsers.init(
            parsers: [{:json, length: 1_000_000}],
            pass: ["application/json"],
            json_decoder: JSON
          )
  defp call(conn, opts) do
    conn
    |> Plug.Parsers.call(@parser)
    |> Phantom.Plug.call(opts)
  end
end

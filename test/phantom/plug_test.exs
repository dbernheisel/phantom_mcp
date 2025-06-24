defmodule Phantom.PlugTest do
  use ExUnit.Case

  import Phantom.TestDispatcher
  import Plug.Conn
  import Plug.Test

  doctest Phantom.Plug

  @cors_opts Phantom.Plug.init(
               router: Test.MCP.Router,
               origins: ["http://localhost:4000"],
               validate_origin: true
             )

  setup do
    start_supervised({Phoenix.PubSub, name: Test.PubSub})
    start_supervised({Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]})
    Phantom.Cache.register(Test.MCP.Router)
    :ok
  end

  describe "plug initialization" do
    test "initializes with valid router" do
      opts = Phantom.Plug.init(router: Test.MCP.Router)
      assert opts[:router] == Test.MCP.Router
      assert opts[:validate_origin] == true
      assert opts[:origins] == ["http://localhost:4000"]
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
      request_ping(
        origins: ["http://localhost:4000"],
        validate_origin: true,
        before_call: fn conn ->
          put_req_header(conn, "origin", "http://localhost:4000")
        end
      )

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
      request_ping(
        origins: ["http://localhost:4000"],
        validate_origin: true,
        before_call: fn conn ->
          put_req_header(conn, "origin", "http://evil.example")
        end
      )

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
      request_ping(
        origins: ["http://localhost:4000"],
        validate_origin: false,
        before_call: fn conn ->
          put_req_header(conn, "origin", "http://evil.example:4000")
        end
      )

      assert_receive {:conn, conn}
      assert conn.status == 200
    end

    test "validates origin when enabled" do
      request_ping(
        origins: :all,
        validate_origin: true,
        before_call: fn conn ->
          put_req_header(conn, "origin", "http://any-origin.example")
        end
      )

      assert_receive {:conn, conn}
      assert conn.status == 200
    end
  end

  describe "content length validation" do
    test "rejects requests that exceed max_request_size" do
      request_ping(
        validate_origin: false,
        router: Test.MCP.Router,
        max_request_size: 10,
        before_call: fn conn ->
          put_req_header(conn, "content-length", "100")
        end
      )

      assert_receive {:conn, conn}
      assert conn.status == 413

      error = JSON.decode!(conn.resp_body)
      assert error["error"]["code"] == -32600
      assert error["error"]["message"] == "Request too large"
    end

    test "sets correct content-type headers" do
      request_ping()

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
    end
  end

  describe "malformed requests" do
    test "handles missing body" do
      :post
      |> conn("/mcp")
      |> call()

      assert_receive {:conn, conn}
      assert conn.status == 400
      error = JSON.decode!(conn.resp_body)

      assert error["error"]["code"] == -32700
      assert error["error"]["message"] == "Parse error: Invalid JSON"
    end

    test "handles valid JSON-RPC request" do
      request_ping()
      assert_receive {:conn, conn}
      assert conn.status == 200
      assert_receive {:response, _id, _event, %{id: 1, jsonrpc: "2.0", result: %{}}}
    end

    test "returns error for invalid JSON-RPC" do
      :post
      |> conn("/mcp", %{method: "foo", id: 1})
      |> put_req_header("content-type", "application/json")
      |> call()

      assert_connected(conn)
      assert conn.status == 200

      assert_receive {:response, 1, "message", error}
      assert error[:error][:code] == -32600
      assert error[:error][:message] == "Invalid request"
    end

    test "rejects unsupported methods" do
      :put
      |> conn("/mcp")
      |> call()

      assert_receive {:conn, conn}
      assert conn.status == 405

      assert_receive {_, {405, _headers, body}}
      error = JSON.decode!(body)
      assert error["error"]["code"] == -32601
      assert error["error"]["message"] == "Method not allowed"
    end

    test "handles batch requests" do
      batch = [
        %{jsonrpc: "2.0", method: "ping", id: 1},
        %{
          jsonrpc: "2.0",
          method: "tools/call",
          id: 2,
          params: %{name: "echo_tool", arguments: %{message: "test"}}
        }
      ]

      :post
      |> conn("/mcp", JSON.encode!(batch))
      |> put_req_header("content-type", "application/json")
      |> call()

      assert_connected(_conn)
      assert_receive {:response, 1, "message", %{}}

      assert_receive {:response, 2, "message",
                      %{result: %{content: [%{text: "test", type: "text"}]}}}

      assert_receive {:response, nil, "closed", "finished"}
    end
  end

  describe "SSE handling" do
    test "GET request returns error" do
      :get
      |> conn("/mcp")
      |> put_req_header("accept", "text/event-stream")
      |> call(pubsub: nil)

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
      |> call()

      assert_sse_connected()
      assert Phantom.Session.list_streams() != []
    end
  end

  test "handles prompt responses" do
    request_prompt("resource_prompt", id: 1)
    assert_response(1, response)

    assert %{
             description: "A resource prompt",
             messages: [
               %{
                 role: :assistant,
                 content: %{
                   type: :resource,
                   resource: %{
                     uri: "test:///text/321",
                     mimeType: "application/json",
                     text: ~s|{"id":"321"}|
                   }
                 }
               },
               %{role: :user, content: %{type: :text, text: "Wowzers"}}
             ]
           } = response[:result]
  end

  test "handles asyncronous prompt responses" do
    request_prompt("async_resource_prompt", %{}, id: 4)

    assert_response(4, response)

    assert %{
             description: "A resource prompt that has an async read",
             messages: [
               %{
                 role: :assistant,
                 content: %{
                   type: :resource,
                   resource: %{
                     uri: "myapp:///binary/foo",
                     mimeType: "image/png",
                     blob: blob
                   }
                 }
               },
               %{role: :user, content: %{type: :text, text: "Wowzers"}}
             ]
           } = response[:result]

    # Verify it's valid base64 encoded data
    assert is_binary(blob)
    assert {:ok, decoded} = Base.decode64(blob)
    assert File.read!("test/support/fixtures/foo.png") == decoded
  end

  test "handles embedded resource link" do
    request_tool("embedded_resource_link_tool", %{}, id: 42)
    assert_response(42, response)

    assert %{
             content: [
               %{
                 type: :resource_link,
                 description: "An image resource",
                 uri: "myapp:///binary/foo"
               }
             ]
           } = response[:result]
  end

  test "handles asynchronous tool responses" do
    request_tool("async_embedded_resource_tool", %{}, id: 43)
    assert_response(43, response)

    assert %{
             content: [
               %{
                 type: :resource,
                 resource: %{
                   uri: "myapp:///binary/foo",
                   mimeType: "image/png",
                   blob: blob
                 }
               }
             ]
           } = response[:result]

    # Verify it's valid base64 encoded data
    assert is_binary(blob)
    assert {:ok, decoded} = Base.decode64(blob)
    assert File.read!("test/support/fixtures/foo.png") == decoded
  end

  test "handles asynchronous resource responses" do
    request_resource_read("myapp:///binary/bar", id: 2)
    assert_response(2, response)

    assert %{
             contents: [
               %{
                 uri: "myapp:///binary/bar",
                 mimeType: "image/png",
                 blob: blob
               }
             ]
           } = response[:result]

    # Verify it's valid base64 encoded data
    assert is_binary(blob)
    assert {:ok, decoded} = Base.decode64(blob)
    assert File.read!("test/support/fixtures/bar.png") == decoded
  end

  test "handles resource not found" do
    # Test reading a resource that doesn't exist
    not_found_message = %{
      jsonrpc: "2.0",
      method: "resources/read",
      id: 5,
      params: %{uri: "nonexistent:///missing/resource"}
    }

    :post
    |> conn("/mcp", not_found_message)
    |> put_req_header("content-type", "application/json")
    |> call()

    assert_connected(conn)
    assert conn.status == 200

    assert_response(5, response)
    assert response[:jsonrpc] == "2.0"
    assert response[:id] == 5
    assert is_map(response[:error])

    error = response[:error]
    assert error[:code] == -32602
    assert error[:message] == "Invalid Params"
  end

  test "handles sending logs", context do
    session_id = to_string(context.test)

    request_sse_stream(session_id: session_id)
    assert_sse_connected()

    request_set_log_level("debug", id: 2, session_id: session_id)
    assert_connected(%{status: 200})
    assert_response(2, %{})

    request_resource_read("myapp:///binary/bar",
      id: 3,
      session_id: session_id
    )

    assert_connected(%{status: 200})
    assert_response(3, _)

    assert_notify(%{
      method: "notifications/message",
      params: %{
        data: %{message: "An info log"},
        logger: "server",
        level: :info
      }
    })
  end

  test "handles resource subscriptions", context do
    session_id = to_string(context.test)

    request_sse_stream(session_id: session_id)
    assert_sse_connected()

    {:ok, uri} = Phantom.Router.resource_uri(Test.MCP.Router, :text_resource, id: 100)

    request_resource_subscribe(uri, id: 2, session_id: session_id)
    assert_connected(_conn)
    assert_response(2, %{result: nil})

    Phoenix.PubSub.local_broadcast(
      Test.PubSub,
      Phantom.Session.resource_subscription_topic(),
      {:resource_updated, uri}
    )

    assert_notify(%{
      method: "notifications/resources/updated",
      params: %{uri: ^uri}
    })
  end
end

defmodule Phantom.RouterTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Phantom.TestDispatcher
  import Plug.Conn
  import Plug.Test

  doctest Phantom.Plug

  setup do
    start_supervised({Phoenix.PubSub, name: Test.PubSub})
    start_supervised({Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]})
    Phantom.Cache.register(Test.MCP.Router)
    :ok
  end

  test "dispatches to tools" do
    request_tool("echo_tool", %{message: "hello world"})

    assert_receive {:conn, conn}
    assert conn.status == 200

    response = %{
      id: 1,
      jsonrpc: "2.0",
      result: %{
        content: [%{text: "hello world", type: "text"}]
      }
    }

    assert_receive {:response, _id, _event, ^response}
  end

  test "handles notifications (no id)" do
    :post
    |> conn("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "notification"}))
    |> put_req_header("content-type", "application/json")
    |> call()

    assert_receive {:conn, conn}
    assert conn.status == 200
    assert_receive {:response, nil, "message", %{id: nil, result: nil, jsonrpc: "2.0"}}
  end

  test "returns error for unknown method" do
    :post
    |> conn("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "unknown", id: 1}))
    |> put_req_header("content-type", "application/json")
    |> call()

    assert_receive {:conn, conn}
    assert conn.status == 200

    assert_receive {:response, 1, "message", error}
    assert error[:error][:code] == -32601
    assert error[:error][:message] == "Method not found"
  end

  test "handles router errors when there's batched calls" do
    Process.flag(:trap_exit, true)

    capture_log(fn ->
      pid =
        :post
        |> conn("/mcp", %{
          "_json" => [
            %{
              jsonrpc: "2.0",
              id: 1,
              method: "tools/call",
              params: %{"name" => "explode_tool"}
            },
            %{
              jsonrpc: "2.0",
              id: 2,
              method: "tools/call",
              params: %{"name" => "explode_tool"}
            }
          ]
        })
        |> put_req_header("content-type", "application/json")
        |> call()

      assert_receive {:response, 1, "message", error}
      assert_receive {:EXIT, ^pid, {exception, _stacktrace}}

      assert %{
               error: %{code: -32603, message: "boom"},
               id: 1,
               jsonrpc: "2.0"
             } = error

      assert %Phantom.ErrorWrapper{} = exception

      assert [
               {
                 %{params: %{"name" => "explode_tool"}},
                 %RuntimeError{message: "boom"},
                 _stacktrace_one
               },
               {
                 %{params: %{"name" => "explode_tool"}},
                 %RuntimeError{message: "boom"},
                 _stacktrace_two
               }
             ] = exception.exceptions_by_request
    end)
  end

  test "handles router errors when there's a single request" do
    Process.flag(:trap_exit, true)

    capture_log(fn ->
      request_tool("explode_tool", %{}, id: 4)
      assert_exception_response(4, error, {exception, _stacktrace})

      assert %{
               error: %{code: -32603, message: "boom"},
               id: 4,
               jsonrpc: "2.0"
             } = error

      assert %RuntimeError{message: "boom"} = exception
    end)
  end

  describe "resource URI matching" do
    test "routes the requested resource to the correct remote handler" do
      request_resource_read("test:///text/many/1")

      assert_receive {:conn, conn}
      assert conn.status == 200
      assert_receive {:response, 1, "message", response}

      assert %{
               jsonrpc: "2.0",
               id: 1,
               result: %{contents: contents}
             } = response

      assert %{
               uri: "test:///text/many/1",
               mimeType: "text/plain",
               text: "1"
             } in contents

      assert length(contents) == 10
    end

    test "routes the requested resource to the correct function handler" do
      request_resource_read("test:///text/1")

      assert_receive {:conn, conn}
      assert conn.status == 200
      assert_receive {:response, 1, "message", response}

      assert %{
               jsonrpc: "2.0",
               id: 1,
               result: %{
                 contents: [
                   %{
                     uri: "test:///text/1",
                     text: ~S|{"id":"1"}|
                   }
                 ]
               }
             } = response
    end
  end

  describe "authentication" do
    defmodule Test.UnauthorizedRouter do
      @instructions """
      A test MCP router that requires authentication and returns unauthorized responses.
      """

      use Phantom.Router,
        name: "UnauthorizedTest",
        vsn: "1.0",
        validate_origin: false,
        instructions: @instructions

      @doc """
      Connect callback that always returns unauthorized with WWW-Authenticate header
      """
      def connect(_session, _headers) do
        www_authenticate = %{
          method: "Bearer",
          realm: "mcp-server",
          scope: "read write"
        }

        {:unauthorized, www_authenticate}
      end
    end

    test "connect callback responds with unauthorized and www-authenticate header (map format)" do
      Phantom.Cache.register(Test.UnauthorizedRouter)

      :post
      |> conn("/mcp", %{jsonrpc: "2.0", method: "ping", id: 1})
      |> put_req_header("content-type", "application/json")
      |> call(router: Test.UnauthorizedRouter)

      assert_receive {:conn, conn}
      assert conn.status == 401

      # Verify WWW-Authenticate header is present and properly formatted
      [www_auth_header] = get_resp_header(conn, "www-authenticate")
      assert www_auth_header =~ "Bearer"
      assert www_auth_header =~ ~s|realm="mcp-server"|
      assert www_auth_header =~ ~s|scope="read write"|

      # Verify the response body contains the correct error
      response_body = JSON.decode!(conn.resp_body)
      assert response_body["error"]["code"] == -32000
      assert response_body["error"]["message"] == "Unauthorized"
      assert response_body["jsonrpc"] == "2.0"
      # ID may be nil in error responses during connection phase
      refute response_body["id"]
    end

    test "connect callback responds with unauthorized and www-authenticate header (string format)" do
      # Create a router that returns a string www-authenticate header
      defmodule Test.UnauthorizedStringRouter do
        use Phantom.Router,
          name: "UnauthorizedStringTest",
          vsn: "1.0",
          validate_origin: false,
          instructions: "Test router with string www-authenticate"

        def connect(_session, _headers) do
          {:unauthorized, "Bearer realm=\"string-test\", scope=\"read\""}
        end
      end

      Phantom.Cache.register(Test.UnauthorizedStringRouter)

      :post
      |> conn("/mcp", %{
        jsonrpc: "2.0",
        method: "initialize",
        id: 2,
        params: %{
          protocolVersion: "2024-11-05",
          capabilities: %{},
          clientInfo: %{name: "TestClient", version: "1.0.0"}
        }
      })
      |> put_req_header("content-type", "application/json")
      |> call(router: Test.UnauthorizedStringRouter)

      assert_receive {:conn, conn}
      assert conn.status == 401

      # Verify string WWW-Authenticate header
      [www_auth_header] = get_resp_header(conn, "www-authenticate")
      assert www_auth_header == "Bearer realm=\"string-test\", scope=\"read\""

      # Verify error response
      response_body = JSON.decode!(conn.resp_body)
      assert response_body["error"]["code"] == -32000
      assert response_body["error"]["message"] == "Unauthorized"
      # ID may be nil in error responses during connection phase
      refute response_body["id"]
    end
  end
end

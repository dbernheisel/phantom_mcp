defmodule PhantomTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  doctest Phantom.Plug

  @opts Phantom.Plug.init(
          router: Test.MCPRouter,
          pubsub: Test.PubSub,
          validate_origin: false
        )

  @ping_message %{jsonrpc: "2.0", method: "ping", id: 1}

  setup do
    Phantom.Cache.register(Test.MCPRouter)
  end

  describe "JSON-RPC requests" do
    test "handles valid JSON-RPC request" do
      :post
      |> conn("/mcp", @ping_message)
      |> put_req_header("content-type", "application/json")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200
      expected = %{id: 1, jsonrpc: "2.0", result: %{}}
      assert_receive {:response, _id, _event, ^expected}
    end

    test "dispatches to tools" do
      params = %{
        name: "echo_tool",
        arguments: %{message: "hello world"}
      }

      :post
      |> conn("/mcp", %{jsonrpc: "2.0", id: 1, method: "tools/call", params: params})
      |> put_req_header("content-type", "application/json")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200

      response = %{
        id: 1,
        jsonrpc: "2.0",
        result: %{content: [%{text: "hello world", type: "text"}]}
      }

      assert_receive {:response, _id, _event, ^response}
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
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200

      expected_one = %{
        id: 1,
        jsonrpc: "2.0",
        result: %{}
      }

      assert_receive {:response, _id, _event, ^expected_one}

      expected_two =
        %{
          id: 2,
          jsonrpc: "2.0",
          result: %{
            content: [%{text: "test", type: "text"}]
          }
        }

      assert_receive {:response, 2, "message", ^expected_two}
    end

    test "handles notifications (no id)" do
      :post
      |> conn("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "notification"}))
      |> put_req_header("content-type", "application/json")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200
      assert_receive {:response, nil, "message", %{id: nil, result: nil, jsonrpc: "2.0"}}
    end

    test "returns error for invalid JSON-RPC" do
      :post
      |> conn("/mcp", %{method: "foo", id: 1})
      |> put_req_header("content-type", "application/json")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", error}
      assert error[:error][:code] == -32600
      assert error[:error][:message] == "Invalid request"
    end

    test "returns error for unknown method" do
      :post
      |> conn("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "unknown", id: 1}))
      |> put_req_header("content-type", "application/json")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert_receive {:response, 1, "message", error}
      assert error[:error][:code] == -32601
      assert error[:error][:message] == "Method not found"
    end

    test "handles router errors" do
      params = %{"name" => "explode_tool"}
      Process.flag(:trap_exit, true)

      capture_log(fn ->
        pid =
          :post
          |> conn("/mcp", %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: params
          })
          |> put_req_header("content-type", "application/json")
          |> call(@opts)

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
                   _stacktrace
                 }
               ] = exception.exceptions_by_request
      end)
    end
  end

  describe "HTTP method handling" do
    test "rejects unsupported methods" do
      :put
      |> conn("/mcp")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 405

      assert_receive {_, {405, _headers, body}}
      error = JSON.decode!(body)
      assert error["error"]["code"] == -32601
      assert error["error"]["message"] == "Method not allowed"
    end
  end

  describe "response formatting" do
    test "sets correct content-type headers" do
      :post
      |> conn("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "ping", id: 1}))
      |> put_req_header("content-type", "application/json")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
    end
  end

  describe "resource URI matching" do
    test "routes the requested resource to the correct remote handler" do
      :post
      |> conn("/mcp", %{
        jsonrpc: "2.0",
        id: "1",
        method: "resources/read",
        params: %{uri: "test:///example/1"}
      })
      |> put_req_header("content-type", "application/json")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200
      assert_receive {:response, "1", "message", response}

      assert %{
               jsonrpc: "2.0",
               id: "1",
               result: %{
                 contents: [
                   %{
                     mimeType: "application/json",
                     uri: "test:///example/1",
                     text: ~S|{"id":"1"}|
                   }
                 ]
               }
             } = response
    end

    test "routes the requested resource to the correct function handler" do
      :post
      |> conn("/mcp", %{
        jsonrpc: "2.0",
        id: "1",
        method: "resources/read",
        params: %{uri: "test:///example/1"}
      })
      |> put_req_header("content-type", "application/json")
      |> call(@opts)

      assert_receive {:conn, conn}
      assert conn.status == 200
      assert_receive {:response, "1", "message", response}

      assert %{
               jsonrpc: "2.0",
               id: "1",
               result: %{
                 contents: [
                   %{
                     mimeType: "application/json",
                     uri: "test:///example/1",
                     text: ~S|{"id":"1"}|
                   }
                 ]
               }
             } = response
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

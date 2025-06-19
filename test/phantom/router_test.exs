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
        structuredContent: %{message: "hello world"},
        content: [%{text: ~S|{"message":"hello world"}|, type: "text"}]
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
end

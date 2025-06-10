defmodule PhantomTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  doctest Phantom.Plug

  @opts Phantom.Plug.init(
          router: Test.MCPRouter,
          validate_origin: false
        )

  @ping_message %{jsonrpc: "2.0", method: "ping", id: 1}

  setup do
    Phantom.Cache.register(Test.MCPRouter)
  end

  describe "JSON-RPC requests" do
    test "handles valid JSON-RPC request" do
      conn =
        :post
        |> conn("/mcp", @ping_message)
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      assert conn.status == 200
      response = conn.resp_body |> JSON.decode!()
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"] == %{}
    end

    test "dispatches to tools" do
      params = %{
        name: "echo_tool",
        arguments: %{message: "hello world"}
      }

      conn =
        :post
        |> conn("/mcp", %{jsonrpc: "2.0", id: 1, method: "tools/call", params: params})
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      assert conn.status == 200
      response = JSON.decode!(conn.resp_body)
      assert [%{"text" => "hello world", "type" => "text"}] = response["result"]["content"]
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

      conn =
        :post
        |> conn("/mcp", JSON.encode!(batch))
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      assert conn.status == 200
      [_, _] = responses = JSON.decode!(conn.resp_body)

      assert Enum.find(responses, &(&1["id"] == 1)) == %{
               "id" => 1,
               "jsonrpc" => "2.0",
               "result" => %{}
             }

      assert Enum.find(responses, &(&1["id"] == 2)) == %{
               "id" => 2,
               "jsonrpc" => "2.0",
               "result" => %{
                 "content" => [%{"text" => "test", "type" => "text"}]
               }
             }
    end

    test "handles notifications (no id)" do
      conn =
        :post
        |> conn("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "notification"}))
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      # Notifications should not return a response in batch, but single notifications still get 200
      assert conn.status == 200
    end

    test "returns error for invalid JSON-RPC" do
      conn =
        :post
        |> conn("/mcp", %{method: "foo", id: 1})
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      assert conn.status == 200
      response = conn.resp_body |> JSON.decode!()
      assert response["error"]["code"] == -32600
      assert response["error"]["message"] == "Invalid Request"
    end

    test "returns error for unknown method" do
      conn =
        :post
        |> conn("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "unknown", id: 1}))
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      assert conn.status == 200
      response = conn.resp_body |> JSON.decode!()
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] == "Method not found"
    end

    test "handles router errors" do
      params = %{"name" => "explode_tool"}

      capture_log(fn ->
        error =
          assert_raise Phantom.Plug.Phantom.ErrorWrapper,
                       ~r/Exceptions while processing MCP requests/,
                       fn ->
                         :post
                         |> conn("/mcp", %{
                           jsonrpc: "2.0",
                           id: 1,
                           method: "tools/call",
                           params: params
                         })
                         |> put_req_header("content-type", "application/json")
                         |> call(@opts)
                       end

        assert [
                 {
                   %{
                     "id" => 1,
                     "jsonrpc" => "2.0",
                     "method" => "tools/call",
                     "params" => %{"name" => "explode_tool"}
                   },
                   %RuntimeError{message: "boom"},
                   _stacktrace
                 }
               ] = error.exceptions_by_request
      end)
    end
  end

  describe "HTTP method handling" do
    test "rejects unsupported methods" do
      conn =
        :put
        |> conn("/mcp")
        |> call(@opts)

      assert conn.status == 405
      resp = conn.resp_body |> JSON.decode!()
      assert resp["error"]["code"] == -32601
      assert resp["error"]["message"] == "Method not allowed"
    end
  end

  describe "response formatting" do
    test "sets correct content-type headers" do
      conn =
        :post
        |> conn("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "ping", id: 1}))
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end

    test "encodes response as valid JSON" do
      conn =
        :post
        |> conn("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "ping", id: 1}))
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      assert {:ok, _} = JSON.decode(conn.resp_body)
    end
  end

  describe "SSE handling" do
    test "GET request returns error when session manager disabled" do
      conn =
        :get
        |> conn("/mcp")
        |> put_req_header("accept", "text/event-stream")
        |> call(@opts)

      assert conn.status == 405
      error = conn.resp_body |> JSON.decode!()
      assert error["error"]["message"] == "SSE not supported"
    end
  end

  describe "resource URI matching" do
    test "routes the requested resource to the correct remote handler" do
      conn =
        :post
        |> conn("/mcp", %{
          jsonrpc: "2.0",
          id: "1",
          method: "resources/read",
          params: %{uri: "test:///example/1"}
        })
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      assert conn.status == 200

      assert %{
               "jsonrpc" => "2.0",
               "id" => "1",
               "result" => %{
                 "contents" => [
                   %{
                     "mimeType" => "application/json",
                     "uri" => "test:///example/1",
                     "text" => ~S|{"id":"1"}|
                   }
                 ]
               }
             } = JSON.decode!(conn.resp_body)
    end

    test "routes the requested resource to the correct function handler" do
      conn =
        :post
        |> conn("/mcp", %{
          jsonrpc: "2.0",
          id: "1",
          method: "resources/read",
          params: %{uri: "test:///example/1"}
        })
        |> put_req_header("content-type", "application/json")
        |> call(@opts)

      assert conn.status == 200

      assert %{
               "jsonrpc" => "2.0",
               "id" => "1",
               "result" => %{
                 "contents" => [
                   %{
                     "mimeType" => "application/json",
                     "uri" => "test:///example/1",
                     "text" => ~S|{"id":"1"}|
                   }
                 ]
               }
             } = JSON.decode!(conn.resp_body)
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

defmodule Phantom.RequestTest do
  use ExUnit.Case, async: true

  alias Phantom.Request

  describe "build/1 captures _meta from params" do
    test "extracts an empty meta when params has no _meta" do
      assert {:ok, %Request{meta: %{}}} =
               Request.build(%{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "tools/call",
                 "params" => %{"name" => "echo"}
               })
    end

    test "extracts protocolVersion, clientInfo, capabilities" do
      meta = %{
        "protocolVersion" => "2026-07-28",
        "clientInfo" => %{"name" => "TestClient", "version" => "1.0.0"},
        "capabilities" => %{"elicitation" => %{}}
      }

      assert {:ok, %Request{meta: ^meta}} =
               Request.build(%{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "tools/call",
                 "params" => %{"name" => "echo", "_meta" => meta}
               })
    end

    test "extracts W3C trace context fields" do
      meta = %{
        "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        "tracestate" => "rojo=00f067aa0ba902b7",
        "baggage" => "userId=alice"
      }

      assert {:ok, %Request{meta: ^meta}} =
               Request.build(%{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "tools/call",
                 "params" => %{"_meta" => meta}
               })
    end

    test "extracts opaque requestState for multi-round-trip continuation" do
      assert {:ok, %Request{meta: %{"requestState" => "opaque-blob"}}} =
               Request.build(%{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "tools/call",
                 "params" => %{"_meta" => %{"requestState" => "opaque-blob"}}
               })
    end

    test "missing params yields empty meta without crashing" do
      assert {:ok, %Request{meta: %{}, params: %{}}} =
               Request.build(%{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "ping"
               })
    end
  end
end

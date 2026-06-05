defmodule Phantom.RequestTest do
  use ExUnit.Case, async: true

  alias Phantom.Request
  alias Phantom.Session

  defp session_with_protocol(version) do
    %Session{id: "test", request: %Request{meta: %{"protocolVersion" => version}}}
  end

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

  describe "trace_context/1" do
    test "extracts the three W3C fields when present" do
      {:ok, request} =
        Request.build(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping",
          "params" => %{
            "_meta" => %{
              "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
              "tracestate" => "rojo=00f067aa0ba902b7",
              "baggage" => "userId=alice"
            }
          }
        })

      assert Request.trace_context(request) == %{
               traceparent: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
               tracestate: "rojo=00f067aa0ba902b7",
               baggage: "userId=alice"
             }
    end

    test "omits keys that aren't set" do
      {:ok, request} =
        Request.build(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping",
          "params" => %{"_meta" => %{"traceparent" => "x"}}
        })

      assert Request.trace_context(request) == %{traceparent: "x"}
    end

    test "returns an empty map when no _meta is present" do
      {:ok, request} = Request.build(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      assert Request.trace_context(request) == %{}
    end
  end

  describe "with_cache/2" do
    test "adds ttlMs" do
      assert %{ttlMs: 60_000} = Request.with_cache(%{content: []}, ttl_ms: 60_000)
    end

    test "encodes scope as a JSON string" do
      assert %{cacheScope: "public"} = Request.with_cache(%{}, scope: :public)
      assert %{cacheScope: "private"} = Request.with_cache(%{}, scope: :private)
    end

    test "accepts both options at once" do
      assert %{ttlMs: 30_000, cacheScope: "public"} =
               Request.with_cache(%{content: []}, ttl_ms: 30_000, scope: :public)
    end

    test "omits keys when their options are absent" do
      result = Request.with_cache(%{content: []}, [])
      refute Map.has_key?(result, :ttlMs)
      refute Map.has_key?(result, :cacheScope)
    end

    test "preserves all existing keys on the result" do
      result =
        Request.with_cache(
          %{content: [%{type: :text, text: "x"}], structuredContent: %{a: 1}},
          ttl_ms: 10
        )

      assert result.content == [%{type: :text, text: "x"}]
      assert result.structuredContent == %{a: 1}
      assert result.ttlMs == 10
    end
  end

  describe "resource_not_found/2 chooses the JSON-RPC code by protocol version" do
    test "legacy protocols (≤ 2025-11-25) still emit the MCP-custom -32002" do
      session = session_with_protocol("2025-11-25")

      assert %{code: -32002, message: "Resource not found", data: %{uri: "x"}} =
               Request.resource_not_found(%{uri: "x"}, session)
    end

    test "stateless core (2026-07-28) emits the standard -32602 Invalid Params (SEP-2164)" do
      session = session_with_protocol("2026-07-28")

      assert %{code: -32602, message: "Resource not found", data: %{uri: "x"}} =
               Request.resource_not_found(%{uri: "x"}, session)
    end

    test "a session with no recorded protocol version defaults to legacy" do
      assert %{code: -32002} = Request.resource_not_found(%{uri: "x"}, %Session{id: "test"})
    end
  end
end

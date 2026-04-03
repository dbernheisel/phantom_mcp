defmodule Phantom.DistributedTest do
  use Phantom.Test.NodeCase

  @node1_port 4101
  @node2_port 4102

  describe "cross-node elicitation" do
    test "elicitation response routed from node2 back to node1" do
      # Step 1: Initialize on node 1 to establish a session with elicitation capability
      session_id = initialize(@node1_port)
      assert is_binary(session_id)

      # Step 2: POST tools/call for elicit_tool to node 1 (SSE stream stays open)
      tool_resp =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: 42,
            method: "tools/call",
            params: %{name: "elicit_tool", arguments: %{}}
          },
          session_id: session_id
        )

      assert tool_resp.status == 200

      # Step 3: Read the SSE stream to get the elicitation/create request
      {messages, ref, buffer} = receive_sse_event(tool_resp, 10_000)

      elicit_request =
        Enum.find(messages, fn msg -> msg["method"] == "elicitation/create" end)

      assert elicit_request, "Expected elicitation/create request, got: #{inspect(messages)}"
      elicit_id = elicit_request["id"]
      assert is_binary(elicit_id)

      # Step 4: POST the elicitation response to NODE 2 (cross-node routing)
      # Allow Phoenix.Tracker delta replication to propagate across nodes
      Process.sleep(2_000)

      elicit_resp =
        Req.post!("http://127.0.0.1:#{@node2_port}/",
          json: %{
            jsonrpc: "2.0",
            id: elicit_id,
            result: %{
              "action" => "accept",
              "content" => %{
                "name" => "Alice",
                "email" => "alice@test.com",
                "role" => "dev"
              }
            }
          },
          headers: [
            {"content-type", "application/json"},
            {"accept", "application/json"},
            {"mcp-session-id", session_id}
          ]
        )

      assert elicit_resp.status == 202

      # Step 5: Continue reading the SSE stream — the tool result should arrive
      {result_messages, _ref, _buffer} =
        receive_sse_event(tool_resp, ref, buffer, 10_000)

      # Step 6: Assert the tool result contains the elicitation data
      tool_result =
        Enum.find(result_messages, fn msg ->
          is_map_key(msg, "result") and msg["id"] == 42
        end)

      assert tool_result, "Expected tool result with id 42, got: #{inspect(result_messages)}"

      content = tool_result["result"]["content"]
      assert is_list(content)

      text_item = Enum.find(content, fn c -> c["type"] == "text" end)
      assert text_item

      parsed = JSON.decode!(text_item["text"])
      assert parsed["hello"] == "my name is Alice"
    end
  end
end

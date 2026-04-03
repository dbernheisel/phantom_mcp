defmodule Phantom.DistributedTest do
  use Phantom.Test.NodeCase

  @node1 :"node1@127.0.0.1"
  @node2 :"node2@127.0.0.1"
  @node1_port 4101
  @node2_port 4102

  # Initialize and return {session_id, resp, ref, buffer} so the caller
  # can keep reading SSE events from the initialize stream.
  defp initialize_with_stream(port) do
    resp =
      post_mcp(port, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-06-18",
          capabilities: %{roots: %{}, sampling: %{}, elicitation: %{}},
          clientInfo: %{name: "DistributedTestClient", version: "1.0"}
        }
      })

    session_id = session_id(resp)
    {_messages, ref, buffer} = receive_sse_event(resp, 5_000)
    {session_id, resp, ref, buffer}
  end

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

  describe "cross-node notifications" do
    test "resource update notification reaches remote SSE stream" do
      # Step 1: Initialize on node 1, keeping the SSE stream open for notifications
      {session_id, init_resp, ref, buffer} = initialize_with_stream(@node1_port)
      assert is_binary(session_id)

      # Step 2: Get the resource URI from a peer node (cache lives there)
      {:ok, uri} =
        :rpc.call(@node1, Phantom.Router, :resource_uri, [
          Test.MCP.Router,
          :text_resource,
          [id: 100]
        ])

      # Step 3: Subscribe to the resource on node 1
      sub_resp =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: 10,
            method: "resources/subscribe",
            params: %{uri: uri}
          },
          session_id: session_id
        )

      assert sub_resp.status == 200

      # Drain the subscribe response
      receive_sse_event(sub_resp, 5_000)

      # Allow subscription to propagate across nodes
      Process.sleep(2_000)

      # Step 4: Trigger a resource update notification from node 2
      :rpc.call(@node2, Phantom.Tracker, :notify_resource_updated, [uri])

      # Step 5: Read SSE events from the initialize stream — should contain the notification
      {messages, _ref, _buffer} = receive_sse_event(init_resp, ref, buffer, 10_000)

      notification =
        Enum.find(messages, fn msg ->
          msg["method"] == "notifications/resources/updated"
        end)

      assert notification,
             "Expected notifications/resources/updated, got: #{inspect(messages)}"

      assert notification["params"]["uri"] == uri
    end
  end

  describe "cross-node logging" do
    test "client log from tool on node 2 reaches SSE stream on node 1" do
      # Step 1: Initialize on node 1, keeping the SSE stream open for notifications
      {session_id, init_resp, ref, buffer} = initialize_with_stream(@node1_port)
      assert is_binary(session_id)

      # Step 2: Set log level to "info" on node 1
      log_level_resp =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: 20,
            method: "logging/setLevel",
            params: %{level: "info"}
          },
          session_id: session_id
        )

      assert log_level_resp.status == 200

      # Drain the setLevel POST SSE response
      receive_sse_event(log_level_resp, 5_000)

      # The set_log_level handler also sends the response on the init stream.
      # Drain that empty result before proceeding.
      {_setlevel_result, ref, buffer} = receive_sse_event(init_resp, ref, buffer, 5_000)

      # Allow the log level to propagate
      Process.sleep(500)

      # Step 3: Call client_log_tool on node 2 with the same session
      tool_resp =
        post_mcp(
          @node2_port,
          %{
            jsonrpc: "2.0",
            id: 21,
            method: "tools/call",
            params: %{name: "client_log_tool", arguments: %{message: "hello from node2"}}
          },
          session_id: session_id
        )

      assert tool_resp.status == 200

      # Drain the tool response
      receive_sse_event(tool_resp, 5_000)

      # Step 4: Read SSE events from the initialize stream on node 1
      {messages, _ref, _buffer} = receive_sse_event(init_resp, ref, buffer, 10_000)

      log_notification =
        Enum.find(messages, fn msg ->
          msg["method"] == "notifications/message"
        end)

      assert log_notification,
             "Expected notifications/message log entry, got: #{inspect(messages)}"

      assert log_notification["params"]["level"] == "info"
      assert log_notification["params"]["data"]["message"] == "hello from node2"
    end
  end
end

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
      # Initialize on node 1
      session_id = initialize(@node1_port)
      assert is_binary(session_id)

      # POST tools/call to node 1 — triggers elicitation, opens SSE stream
      tool_resp =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: 42,
            method: "tools/call",
            params: %{"name" => "elicit_tool", "arguments" => %{}}
          },
          session_id: session_id
        )

      assert tool_resp.status == 200

      # Read elicitation request from node 1's SSE stream
      elicit_request =
        poll_for_sse_event(tool_resp, 10_000, &(&1["method"] == "elicitation/create"))

      assert elicit_request, "Expected elicitation/create in SSE events"
      elicit_id = elicit_request["id"]

      # POST elicitation response to NODE 2 (different node!)
      elicit_resp =
        Req.post!("http://127.0.0.1:#{@node2_port}/",
          json: %{
            jsonrpc: "2.0",
            id: elicit_id,
            result: %{
              "action" => "accept",
              "content" => %{
                "name" => "DistributedAlice",
                "email" => "alice@distributed.test",
                "role" => "eng"
              }
            }
          },
          headers: [
            {"content-type", "application/json"},
            {"mcp-session-id", session_id}
          ]
        )

      assert elicit_resp.status == 202

      # Read tool result from node 1's SSE stream
      tool_result =
        poll_for_sse_event(tool_resp, 10_000, &is_map_key(&1, "result"))

      assert tool_result, "Expected tool result in SSE events"

      text = get_in(tool_result, ["result", "content", Access.at(0), "text"])
      assert %{"hello" => "my name is DistributedAlice"} = JSON.decode!(text)
    end
  end

  describe "async elicitation (cross-process)" do
    test "elicit from a Task spawned after {:noreply, session}" do
      # This exercises the cross-process elicit path: the tool handler
      # returns `{:noreply, session}` and spawns a Task. The Task then
      # invokes `Session.elicit/3` from outside the original request
      # process — the captured conn / closure state may be stale.
      session_id = initialize(@node1_port)
      assert is_binary(session_id)

      tool_resp =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: 77,
            method: "tools/call",
            params: %{"name" => "async_elicit_tool", "arguments" => %{}}
          },
          session_id: session_id
        )

      assert tool_resp.status == 200

      # The Task must be able to emit `elicitation/create` on the
      # POST SSE stream even though it is running in a different
      # process than the one that opened the stream.
      elicit_request =
        poll_for_sse_event(tool_resp, 10_000, &(&1["method"] == "elicitation/create"))

      assert elicit_request,
             "Expected elicitation/create on POST SSE stream — the async Task could not write to the stream"

      elicit_id = elicit_request["id"]

      # Answer from node 2 to confirm cross-node routing still works
      # for async elicits.
      elicit_resp =
        Req.post!("http://127.0.0.1:#{@node2_port}/",
          json: %{
            jsonrpc: "2.0",
            id: elicit_id,
            result: %{
              "action" => "accept",
              "content" => %{
                "name" => "AsyncBob",
                "email" => "bob@async.test",
                "role" => "eng"
              }
            }
          },
          headers: [
            {"content-type", "application/json"},
            {"mcp-session-id", session_id}
          ]
        )

      assert elicit_resp.status == 202

      tool_result =
        poll_for_sse_event(tool_resp, 10_000, &is_map_key(&1, "result"))

      assert tool_result, "Expected tool result in SSE events"

      text = get_in(tool_result, ["result", "content", Access.at(0), "text"])
      assert %{"hello" => "async my name is AsyncBob"} = JSON.decode!(text)
    end
  end

  describe "duplicate tools/call dedup" do
    # Simulates a client (or retrying load balancer / proxy) that
    # POSTs the same `tools/call` JSON-RPC request to two nodes
    # sharing a session. Two protections must combine:
    #
    #   (1) ingress dedup via `Phantom.Tracker.track_in_flight/2`
    #       — the second dispatch is rejected with an "Invalid
    #       request" (-32600) JSON-RPC error;
    #   (2) deterministic elicitation request ids — if (1) loses
    #       the replication race and both nodes dispatch, the two
    #       `elicitation/create` messages share the same id so
    #       the client can treat them as duplicates.
    test "concurrent duplicate tools/call across nodes is either rejected or idempotent" do
      session_id = initialize(@node1_port)

      tool_call = %{
        jsonrpc: "2.0",
        id: 99,
        method: "tools/call",
        params: %{"name" => "elicit_tool", "arguments" => %{}}
      }

      # Both POSTs must be initiated from the test process so the
      # SSE body chunks (Req `into: :self`) arrive in this inbox.
      # The `elicit_tool` blocks server-side on the elicitation
      # response, so `post_mcp` returns after headers and the
      # bodies stream asynchronously — they are effectively
      # concurrent for our purposes.
      resp1 = post_mcp(@node1_port, tool_call, session_id: session_id)
      resp2 = post_mcp(@node2_port, tool_call, session_id: session_id)

      assert resp1.status == 200
      assert resp2.status == 200

      any_event = fn msg ->
        msg["method"] == "elicitation/create" or is_map_key(msg, "error")
      end

      ev1 = poll_for_sse_event(resp1, 5_000, any_event)
      ev2 = poll_for_sse_event(resp2, 5_000, any_event)

      assert ev1, "node1 produced neither elicitation nor error"
      assert ev2, "node2 produced neither elicitation nor error"

      # Classify each response
      classify = fn
        %{"method" => "elicitation/create", "id" => id} -> {:elicit, id}
        %{"error" => %{"code" => -32600}} -> :duplicate_rejected
        other -> {:other, other}
      end

      c1 = classify.(ev1)
      c2 = classify.(ev2)

      case {c1, c2} do
        # Preferred outcome: ingress dedup caught the duplicate
        {{:elicit, id}, :duplicate_rejected} ->
          answer_and_drain(session_id, id)

        {:duplicate_rejected, {:elicit, id}} ->
          answer_and_drain(session_id, id)

        # Race fallback: both dispatched, but deterministic ids
        # make them idempotent from the client's view
        {{:elicit, id1}, {:elicit, id2}} ->
          assert id1 == id2,
                 "ingress dedup lost the race AND ids diverged: node1=#{id1} node2=#{id2}"

          answer_and_drain(session_id, id1)

        other ->
          flunk("unexpected classification: #{inspect(other)}")
      end
    end
  end

  defp answer_and_drain(session_id, elicit_id) do
    Req.post!("http://127.0.0.1:#{@node1_port}/",
      json: %{
        jsonrpc: "2.0",
        id: elicit_id,
        result: %{"action" => "reject"}
      },
      headers: [
        {"content-type", "application/json"},
        {"mcp-session-id", session_id}
      ]
    )
  end

  describe "cross-node notifications" do
    test "resource update notification reaches remote SSE stream" do
      # Initialize on node 1 and keep init stream open
      {session_id, init_resp, ref, buffer} = initialize_with_stream(@node1_port)
      assert is_binary(session_id)

      # Wait for session to be replicated to node 2
      await_session_tracked(@node2, session_id)

      # Get resource URI from node 1 (cache lives on peer nodes)
      {:ok, uri} =
        :rpc.call(@node1, Phantom.Router, :resource_uri, [
          Test.MCP.Router,
          :text_resource,
          [id: 100]
        ])

      # Subscribe to the resource directly on the init stream via RPC
      init_pid = :rpc.call(@node1, Phantom.Tracker, :get_session, [session_id])
      GenServer.cast(init_pid, {:subscribe_resource, uri})

      # Wait for resource subscription to replicate to node 2
      await_resource_tracked(@node2, uri)

      # Trigger resource update from NODE 2
      :rpc.call(@node2, Phantom.Tracker, :notify_resource_updated, [uri])

      # Read notification from node 1's init stream
      notification =
        poll_for_sse_event(init_resp, ref, buffer, 10_000, fn msg ->
          msg["method"] == "notifications/resources/updated"
        end)

      assert notification,
             "Expected resource update notification on init stream"

      assert notification["params"]["uri"] == uri
    end
  end

  describe "cross-node logging" do
    test "client log from tool on node 2 reaches SSE stream on node 1" do
      # Step 1: Initialize on node 1, keeping the SSE stream open
      {session_id, init_resp, ref, buffer} = initialize_with_stream(@node1_port)
      assert is_binary(session_id)

      # Wait for session to be replicated to node 2
      await_session_tracked(@node2, session_id)

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

      # Wait for the empty result on the init stream — confirms the
      # set_log_level cast was processed by the init stream GenServer
      {_, ref, buffer} =
        case receive_sse_event(init_resp, ref, buffer, 5_000) do
          {msgs, r, b} when is_list(msgs) -> {msgs, r, b}
          {:timeout, r, b} -> {nil, r, b}
        end

      # Step 3: Call client_log_tool on node 2 with the same session.
      # ClientLogger.do_log sends the log cast to Tracker.get_session(id),
      # which finds the init stream PID on node 1 — cross-node delivery.
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

      # Step 4: Read log notification from the init stream on node 1
      log_notification =
        poll_for_sse_event(init_resp, ref, buffer, 10_000, fn msg ->
          msg["method"] == "notifications/message"
        end)

      assert log_notification,
             "Expected notifications/message log entry on init stream"

      assert log_notification["params"]["level"] == "info"
      assert log_notification["params"]["data"]["message"] == "hello from node2"
    end
  end
end

defmodule Phantom.DistributedTest do
  use Phantom.Test.NodeCase

  @node1 :"node1@127.0.0.1"
  @node2 :"node2@127.0.0.1"
  @node1_port 4101
  @node2_port 4102
  @modern_meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
  }

  # Initialize, then open the session's GET stream on the same node. Returns
  # {session_id, resp, ref, buffer} so the caller can keep reading it.
  defp initialize_with_session_stream(port) do
    session_id = initialize(port)
    resp = open_sse(port, session_id: session_id)
    {session_id, resp, resp.body.ref, ""}
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
      # Initialize on node 1 and open the session stream there
      {session_id, stream_resp, ref, buffer} = initialize_with_session_stream(@node1_port)
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

      # Subscribe to the resource directly on the session stream via RPC
      stream_pid = :rpc.call(@node1, Phantom.Tracker, :get_session, [session_id])
      GenServer.cast(stream_pid, {:subscribe_resource, uri})

      # Wait for resource subscription to replicate to node 2
      await_resource_tracked(@node2, uri)

      # Trigger resource update from NODE 2
      :rpc.call(@node2, Phantom.Tracker, :notify_resource_updated, [uri])

      # Read notification from node 1's session stream
      notification =
        poll_for_sse_event(stream_resp, ref, buffer, 10_000, fn msg ->
          msg["method"] == "notifications/resources/updated"
        end)

      assert notification,
             "Expected resource update notification on session stream"

      assert notification["params"]["uri"] == uri
    end
  end

  describe "cross-node logging" do
    test "client log from tool on node 2 reaches SSE stream on node 1" do
      # Step 1: Initialize on node 1, keeping the SSE stream open
      {session_id, stream_resp, ref, buffer} = initialize_with_session_stream(@node1_port)
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

      # The response arrives once the session stream has applied the level.
      assert {[%{"id" => 20, "result" => %{}}], _, _} = receive_sse_event(log_level_resp, 5_000)

      # Step 3: Call client_log_tool on node 2 with the same session.
      # ClientLogger.do_log sends the log cast to Tracker.get_session(id),
      # which finds the session stream PID on node 1 — cross-node delivery.
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

      # Step 4: Read log notification from the session stream on node 1
      log_notification =
        poll_for_sse_event(stream_resp, ref, buffer, 10_000, fn msg ->
          msg["method"] == "notifications/message"
        end)

      assert log_notification,
             "Expected notifications/message log entry on session stream"

      assert log_notification["params"]["level"] == "info"
      assert log_notification["params"]["data"]["message"] == "hello from node2"
    end
  end

  # These requests reach node 2 before `Phantom.Tracker` has replicated the
  # session stream that `initialize` registered on node 1.
  describe "cross-node session messages before Tracker replication" do
    test "logging/setLevel on node 2 applies to the session stream on node 1" do
      {session_id, stream_resp, ref, buffer} = initialize_with_session_stream(@node1_port)

      set_level =
        post_mcp(
          @node2_port,
          %{jsonrpc: "2.0", id: 30, method: "logging/setLevel", params: %{level: "info"}},
          session_id: session_id
        )

      assert %{"result" => %{}} =
               poll_for_sse_event(set_level, 5_000, &(&1["id"] == 30))

      tool =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: 31,
            method: "tools/call",
            params: %{name: "client_log_tool", arguments: %{message: "logged"}}
          },
          session_id: session_id
        )

      assert poll_for_sse_event(tool, 5_000, &(&1["id"] == 31))

      log =
        poll_for_sse_event(stream_resp, ref, buffer, 5_000, fn msg ->
          msg["method"] == "notifications/message"
        end)

      assert log["params"]["data"]["message"] == "logged"
    end

    test "tools/call on node 2 knows the capabilities from initialize on node 1" do
      session_id = initialize(@node1_port)

      tool =
        post_mcp(
          @node2_port,
          %{
            jsonrpc: "2.0",
            id: 50,
            method: "tools/call",
            params: %{"name" => "elicit_tool", "arguments" => %{}}
          },
          session_id: session_id
        )

      assert poll_for_sse_event(tool, 5_000, &(&1["method"] == "elicitation/create"))
    end

    test "resources/subscribe and unsubscribe on node 2 reach the session stream on node 1" do
      {session_id, stream_resp, ref, buffer} = initialize_with_session_stream(@node1_port)

      {:ok, uri} =
        :rpc.call(@node1, Phantom.Router, :resource_uri, [
          Test.MCP.Router,
          :text_resource,
          [id: 7]
        ])

      subscribe =
        post_mcp(
          @node2_port,
          %{jsonrpc: "2.0", id: 40, method: "resources/subscribe", params: %{uri: uri}},
          session_id: session_id
        )

      assert %{"result" => %{}} = poll_for_sse_event(subscribe, 5_000, &(&1["id"] == 40))

      :rpc.call(@node1, Phantom.Tracker, :notify_resource_updated, [uri])

      assert %{"params" => %{"uri" => ^uri}} =
               poll_for_sse_event(stream_resp, ref, buffer, 5_000, fn msg ->
                 msg["method"] == "notifications/resources/updated"
               end)

      unsubscribe =
        post_mcp(
          @node2_port,
          %{jsonrpc: "2.0", id: 41, method: "resources/unsubscribe", params: %{uri: uri}},
          session_id: session_id
        )

      assert %{"result" => %{}} = poll_for_sse_event(unsubscribe, 5_000, &(&1["id"] == 41))
    end
  end

  describe "session termination" do
    test "DELETE on node 2 closes the session stream on node 1" do
      {session_id, stream_resp, ref, buffer} = initialize_with_session_stream(@node1_port)

      delete =
        Req.delete!("http://127.0.0.1:#{@node2_port}/",
          headers: [{"mcp-session-id", session_id}],
          retry: false
        )

      assert delete.status in 200..299
      assert {:closed, _ref, _buffer} = receive_sse_event(stream_resp, ref, buffer, 5_000)
    end
  end

  describe "cross-node task notifications" do
    test "a task update on node 2 reaches a subscriptions/listen stream on node 1" do
      task_id = "task-cross-node"

      meta = %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{
          "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
        }
      }

      stream_resp =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: "listen:tasks",
            method: "subscriptions/listen",
            params: %{"notifications" => %{"taskIds" => [task_id]}, "_meta" => meta}
          },
          headers: [
            {"mcp-protocol-version", "2026-07-28"},
            {"mcp-method", "subscriptions/listen"}
          ]
        )

      await_task_tracked(@node2, task_id)

      assert {:ok, 1} = :rpc.call(@node2, Phantom.Tracker, :notify_task_updated, [task_id])

      notification =
        poll_for_sse_event(stream_resp, 10_000, &(&1["method"] == "notifications/tasks"))

      assert notification, "Expected notifications/tasks on the node 1 listen stream"
      assert notification["params"]["taskId"] == task_id
      assert notification["params"]["status"] == "working"
    end
  end

  describe "cross-node progress" do
    test "a progress reference reaches the request's stream from another node" do
      resp =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: "progress-1",
            method: "tools/call",
            params: %{
              "name" => "remote_progress_tool",
              "arguments" => %{},
              "_meta" => Map.put(@modern_meta, "progressToken", "remote-token")
            }
          },
          headers: [
            {"mcp-protocol-version", "2026-07-28"},
            {"mcp-method", "tools/call"},
            {"mcp-name", "remote_progress_tool"}
          ]
        )

      notification =
        poll_for_sse_event(resp, 10_000, &(&1["method"] == "notifications/progress"))

      assert notification, "Expected notifications/progress from another node"

      assert %{"progressToken" => "remote-token", "progress" => 50, "total" => 100} =
               notification["params"]

      assert notification["params"]["message"] =~ "node"
      refute notification["params"]["message"] =~ "#{@node1}"
    end
  end

  defp await_task_tracked(node, task_id, attempts \\ 100)

  defp await_task_tracked(node, task_id, attempts) when attempts > 0 do
    listeners = :rpc.call(node, Phantom.Tracker, :list_task_listeners, [])

    if Enum.any?(listeners, &match?({^task_id, _}, &1)) do
      :ok
    else
      Process.sleep(50)
      await_task_tracked(node, task_id, attempts - 1)
    end
  end

  defp await_task_tracked(node, task_id, 0),
    do: flunk("Task #{task_id} not visible on #{node} within timeout")

  describe "stateless core (2026-07-28) — no Tracker, no sticky session" do
    # Node A returns `inputRequired` with an encrypted `requestState`.
    # Node B — with no prior knowledge of the original call — decodes the
    # blob using the shared `:secret_key_base`, populates `session.state`,
    # and runs the same tool's resume clause to completion. This is the
    # load-bearing claim of the stateless core: any node can serve any
    # call as long as it shares the secret with the others.
    test "node 1 returns inputRequired; node 2 resumes purely from the encrypted state" do
      first_resp =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{
              "name" => "resume_tool",
              "arguments" => %{"origin" => "test"},
              "_meta" => @modern_meta
            }
          },
          headers: [
            {"mcp-protocol-version", "2026-07-28"},
            {"mcp-method", "tools/call"},
            {"mcp-name", "resume_tool"}
          ]
        )

      assert first_resp.status == 200

      input_required =
        poll_for_sse_event(first_resp, 5_000, fn msg ->
          get_in(msg, ["result", "resultType"]) == "input_required"
        end)

      assert input_required, "Expected inputRequired result from node 1"

      token = input_required["result"]["requestState"]
      assert is_binary(token)
      refute token == ""

      input_requests = input_required["result"]["inputRequests"]
      assert is_map(input_requests) and map_size(input_requests) >= 1

      second_resp =
        post_mcp(
          @node2_port,
          %{
            jsonrpc: "2.0",
            id: 2,
            method: "tools/call",
            params: %{
              "name" => "resume_tool",
              "arguments" => %{},
              "requestState" => token,
              "inputResponses" => %{
                "elicitation" => %{
                  "action" => "accept",
                  "content" => %{"name" => "alice"}
                }
              },
              "_meta" => @modern_meta
            }
          },
          headers: [
            {"mcp-protocol-version", "2026-07-28"},
            {"mcp-method", "tools/call"},
            {"mcp-name", "resume_tool"}
          ]
        )

      assert second_resp.status == 200

      result =
        poll_for_sse_event(second_resp, 5_000, fn msg ->
          get_in(msg, ["result", "content"]) != nil
        end)

      assert result, "Expected tool result from node 2"

      text = get_in(result, ["result", "content", Access.at(0), "text"])
      assert text == "resumed name=alice origin=test"
    end

    test "an invalid requestState on node 2 is rejected as invalid_params" do
      bad_resp =
        post_mcp(
          @node2_port,
          %{
            jsonrpc: "2.0",
            id: 3,
            method: "tools/call",
            params: %{
              "name" => "resume_tool",
              "arguments" => %{"name" => "alice"},
              "requestState" => "not-a-real-token",
              "_meta" => @modern_meta
            }
          },
          headers: [
            {"mcp-protocol-version", "2026-07-28"},
            {"mcp-method", "tools/call"},
            {"mcp-name", "resume_tool"}
          ]
        )

      assert bad_resp.status == 200

      error =
        poll_for_sse_event(bad_resp, 5_000, fn msg ->
          get_in(msg, ["error", "code"]) != nil
        end)

      assert error, "Expected JSON-RPC error response"
      assert error["error"]["code"] == -32602
    end

    test "inline await suspends on node 1 and resumes from a follow-up on node 2" do
      headers = [
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "tools/call"},
        {"mcp-name", "await_tool"}
      ]

      first =
        post_mcp(
          @node1_port,
          %{
            jsonrpc: "2.0",
            id: 10,
            method: "tools/call",
            params: %{"name" => "await_tool", "arguments" => %{}, "_meta" => @modern_meta}
          },
          headers: headers
        )

      %{"result" => %{"resultType" => "input_required", "requestState" => token}} =
        poll_for_sse_event(first, 5_000, &(&1["id"] == 10))

      second =
        post_mcp(
          @node2_port,
          %{
            jsonrpc: "2.0",
            id: 11,
            method: "tools/call",
            params: %{
              "name" => "await_tool",
              "arguments" => %{},
              "_meta" => @modern_meta,
              "requestState" => token,
              "inputResponses" => %{
                "elicitation" => %{"action" => "accept", "content" => %{"color" => "red"}}
              }
            }
          },
          headers: headers
        )

      result = poll_for_sse_event(second, 5_000, &(&1["id"] == 11))
      assert get_in(result, ["result", "content", Access.at(0), "text"]) == "awaited color=red"
    end
  end
end

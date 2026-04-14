defmodule Phantom.StdioTest do
  use ExUnit.Case

  alias Phantom.MockIO

  defp start_stdio(opts \\ []) do
    {:ok, input} = MockIO.start_link()
    {:ok, output} = MockIO.start_link()

    router = Keyword.get(opts, :router, Test.MCP.Router)

    pid =
      start_supervised!(
        {Phantom.Stdio,
         [
           router: router,
           input: input,
           output: output
         ] ++ opts}
      )

    %{input: input, output: output, pid: pid}
  end

  defp send_request(ctx, request) do
    json = JSON.encode!(request)
    MockIO.push_input(ctx.input, json <> "\n")
  end

  defp read_response(ctx) do
    output = MockIO.await_output(ctx.output)

    case parse_responses(output) do
      [response] -> response
      [] -> raise "No response received"
      responses -> raise "Expected 1 response, got #{length(responses)}: #{inspect(responses)}"
    end
  end

  # Sends a ping and drains all output up to and including the pong.
  # This guarantees all preceding async work (casts, notifications) has
  # been processed by the session before returning.
  defp sync(ctx) do
    id = "sync-#{System.unique_integer([:positive])}"
    send_request(ctx, %{jsonrpc: "2.0", id: id, method: "ping"})
    drain_through(ctx, fn r -> r["id"] == id end)
  end

  # Reads output chunks until predicate matches, discarding everything.
  defp drain_through(ctx, predicate) do
    output = MockIO.await_output(ctx.output)

    unless Enum.any?(parse_responses(output), predicate) do
      drain_through(ctx, predicate)
    end
  end

  defp parse_responses(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  # Collects all responses until one matches the predicate.
  defp collect_until(ctx, predicate) do
    output = MockIO.await_output(ctx.output)
    responses = parse_responses(output)

    if Enum.any?(responses, predicate) do
      responses
    else
      responses ++ collect_until(ctx, predicate)
    end
  end

  setup do
    Phantom.Cache.register(Test.MCP.Router)
    :ok
  end

  describe "child_spec/1" do
    test "returns a valid child spec" do
      spec = Phantom.Stdio.child_spec(router: Test.MCP.Router)
      assert spec.id == Phantom.Stdio
      assert spec.start == {Phantom.Stdio, :start_link, [[router: Test.MCP.Router]]}
    end
  end

  describe "initialize handshake" do
    test "responds to initialize request" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-03-26",
          capabilities: %{},
          clientInfo: %{name: "TestClient", version: "1.0"}
        }
      })

      response = read_response(ctx)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["protocolVersion"] == "2025-03-26"
      assert response["result"]["serverInfo"]["name"] == "Test"
      assert response["result"]["serverInfo"]["version"] == "1.0"
      assert is_map(response["result"]["capabilities"])
    end
  end

  describe "ping" do
    test "responds to ping with pong" do
      ctx = start_stdio()

      send_request(ctx, %{jsonrpc: "2.0", id: 1, method: "ping"})

      response = read_response(ctx)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"] == %{}
    end
  end

  describe "tools/call" do
    test "calls a tool and returns result" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "echo_tool", arguments: %{message: "hello stdio"}}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert response["result"]["content"]
      text = hd(response["result"]["content"])
      assert text["type"] == "text"
      assert text["text"] == "hello stdio"
    end

    test "handles tool errors" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "with_error_tool", arguments: %{}}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert response["result"]["isError"] == true
    end

    test "handles tool exceptions without crashing" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "explode_tool", arguments: %{}}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert response["error"]
      assert response["error"]["code"] == -32603

      # Process should still be alive
      assert Process.alive?(ctx.pid)
    end
  end

  describe "tools/list" do
    test "lists available tools" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/list",
        params: %{}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      tools = response["result"]["tools"]
      assert is_list(tools)
      tool_names = Enum.map(tools, & &1["name"])
      assert "echo_tool" in tool_names
    end
  end

  describe "prompts/get" do
    test "gets a prompt" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "prompts/get",
        params: %{name: "text_prompt", arguments: %{code: "IO.puts(:hello)"}}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert response["result"]["messages"]
      messages = response["result"]["messages"]
      assert length(messages) == 2
    end
  end

  describe "resources/read" do
    test "reads a text resource" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "resources/read",
        params: %{uri: "test:///text/42"}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert response["result"]["contents"]
    end

    test "returns error for unrecognized URI scheme" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "resources/read",
        params: %{uri: "nonexistent:///missing/resource"}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "Invalid Params"
    end

    test "returns error for unmatched URI template" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "resources/read",
        params: %{uri: "test:///nonexistent/path"}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert is_nil(response["result"])
      assert response["error"]["code"] == -32002
      assert response["error"]["message"] == "Resource not found"
      assert response["error"]["data"]["uri"] == "test:///nonexistent/path"
    end

    test "returns error when resource handler returns nil" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "resources/read",
        params: %{uri: "test:///unfound/1"}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert is_nil(response["result"])
      assert response["error"]["code"] == -32002
      assert response["error"]["message"] == "Resource not found"
    end

    test "returns error when resource handler raises" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "resources/read",
        params: %{uri: "explode:///1"}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert response["error"]["code"] == -32603
      assert Process.alive?(ctx.pid)
    end
  end

  describe "parse errors" do
    test "handles invalid JSON gracefully" do
      ctx = start_stdio()

      MockIO.push_input(ctx.input, "not valid json\n")

      response = read_response(ctx)
      assert response["error"]
      assert response["error"]["code"] == -32700

      # Process should still be alive
      assert Process.alive?(ctx.pid)
    end

    test "handles invalid JSON-RPC" do
      ctx = start_stdio()

      send_request(ctx, %{not_jsonrpc: true})

      response = read_response(ctx)
      assert response["error"]
      assert response["error"]["code"] == -32600

      assert Process.alive?(ctx.pid)
    end
  end

  describe "notifications" do
    test "does not respond to notifications (no id)" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        method: "notifications/initialized"
      })

      # Use a ping as a barrier — if the notification had produced output
      # it would appear before the pong.
      send_request(ctx, %{jsonrpc: "2.0", id: "barrier", method: "ping"})
      output = MockIO.await_output(ctx.output)
      responses = parse_responses(output)

      assert [%{"id" => "barrier"}] = responses
    end
  end

  describe "async tool responses" do
    test "handles async tool that responds later" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "async_echo_tool", arguments: %{message: "async hello"}}
      })

      response = read_response(ctx)
      assert response["id"] == 1
      assert response["result"]["content"]
      text = hd(response["result"]["content"])
      assert text["text"] == "async hello"
    end
  end

  describe "EOF shutdown" do
    test "shuts down gracefully on EOF" do
      ctx = start_stdio()
      ref = Process.monitor(ctx.pid)

      MockIO.push_eof(ctx.input)

      assert_receive {:DOWN, ^ref, :process, _, reason}, 2000
      assert reason in [:normal, {:shutdown, :eof}]
    end
  end

  describe "sequential requests" do
    test "handles multiple sequential requests" do
      ctx = start_stdio()

      send_request(ctx, %{jsonrpc: "2.0", id: 1, method: "ping"})
      response1 = read_response(ctx)
      assert response1["id"] == 1

      send_request(ctx, %{jsonrpc: "2.0", id: 2, method: "ping"})
      response2 = read_response(ctx)
      assert response2["id"] == 2
    end
  end

  describe "logging" do
    test "logging capability is advertised in initialize response" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-03-26",
          capabilities: %{},
          clientInfo: %{name: "TestClient", version: "1.0"}
        }
      })

      response = read_response(ctx)
      assert response["result"]["capabilities"]["logging"] == %{}
    end

    test "logging/setLevel returns success" do
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "logging/setLevel",
        params: %{level: "debug"}
      })

      output = MockIO.await_output(ctx.output)
      responses = parse_responses(output)

      assert Enum.any?(responses, fn r ->
               r["id"] == 1 and is_map(r["result"])
             end)
    end

    test "ClientLogger sends notifications/message in stdio" do
      ctx = start_stdio()

      # Set log level to info and sync to ensure it's applied
      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "logging/setLevel",
        params: %{level: "info"}
      })

      sync(ctx)

      # Call a tool that uses ClientLogger.log to send a log notification
      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: %{name: "client_log_tool", arguments: %{message: "mcp-log-test-marker"}}
      })

      # The ClientLogger cast is processed after the tool response, so use
      # a barrier to ensure it's flushed.
      before = collect_until(ctx, fn r -> r["id"] == 2 end)
      send_request(ctx, %{jsonrpc: "2.0", id: "log-barrier", method: "ping"})
      after_ = collect_until(ctx, fn r -> r["id"] == "log-barrier" end)
      all_responses = before ++ after_

      assert Enum.any?(all_responses, fn r ->
               r["method"] == "notifications/message" and
                 is_map(r["params"]) and
                 get_in(r, ["params", "data", "message"])
                 |> to_string()
                 |> String.contains?("mcp-log-test-marker")
             end)
    end
  end

  describe "telemetry" do
    test "emits connect event on startup" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:phantom, :stdio, :connect]])
      ctx = start_stdio()

      assert_receive {[:phantom, :stdio, :connect], ^ref, %{},
                      %{session: _, router: Test.MCP.Router}}

      # cleanup: stop the stdio process so the handler is detached
      stop_supervised!(Phantom.Stdio)
      _ = ctx
    end

    test "emits terminate event on EOF" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:phantom, :stdio, :terminate]])
      ctx = start_stdio()
      monitor = Process.monitor(ctx.pid)

      MockIO.push_eof(ctx.input)

      assert_receive {[:phantom, :stdio, :terminate], ^ref, %{},
                      %{session: _, router: Test.MCP.Router, reason: :eof}}

      assert_receive {:DOWN, ^monitor, :process, _, _}, 2000
    end

    test "emits exception event on tool crash" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:phantom, :stdio, :exception]])
      ctx = start_stdio()

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "explode_tool", arguments: %{}}
      })

      assert_receive {[:phantom, :stdio, :exception], ^ref, %{},
                      %{
                        session: _,
                        router: Test.MCP.Router,
                        exception: %RuntimeError{},
                        stacktrace: _,
                        request: _
                      }}

      # Process should still be alive
      response = read_response(ctx)
      assert response["error"]["code"] == -32603
      assert Process.alive?(ctx.pid)
    end
  end

  describe "connect callback" do
    defmodule RejectRouter do
      use Phantom.Router,
        name: "Reject",
        vsn: "1.0"

      def connect(_session, _auth_info) do
        {:error, "connection rejected"}
      end
    end

    test "handles connect failure" do
      {:ok, input} = MockIO.start_link()
      {:ok, output} = MockIO.start_link()

      Phantom.Cache.register(RejectRouter)

      assert {:error, {"connection rejected", _}} =
               start_supervised(
                 {Phantom.Stdio, router: RejectRouter, input: input, output: output}
               )
    end
  end

  describe "elicitation" do
    defp initialize_with_elicitation(ctx) do
      send_request(ctx, %{
        jsonrpc: "2.0",
        id: "init",
        method: "initialize",
        params: %{
          protocolVersion: "2025-06-18",
          capabilities: %{elicitation: %{}},
          clientInfo: %{name: "TestClient", version: "1.0"}
        }
      })

      drain_through(ctx, fn r -> r["id"] == "init" end)
    end

    test "async elicit — Task spawned in tool emits elicitation and receives response" do
      # Regression: the async stdio elicit path routes response
      # lookup through `Phantom.Tracker.await_request_meta/1`, which
      # is unavailable when the tracker isn't in the supervision
      # tree (default for stdio). Without a local fallback, the
      # response is dropped and the Task times out — meaning the
      # tool never produces a result.
      ctx = start_stdio()
      initialize_with_elicitation(ctx)

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 42,
        method: "tools/call",
        params: %{name: "async_elicit_tool", arguments: %{}}
      })

      elicit =
        find_in_output(ctx, fn r -> r["method"] == "elicitation/create" end, 2_000)

      assert elicit, "expected elicitation/create on output"
      elicit_id = elicit["id"]

      send_request(ctx, %{
        jsonrpc: "2.0",
        id: elicit_id,
        result: %{
          "action" => "accept",
          "content" => %{
            "name" => "Stdio Alice",
            "email" => "alice@stdio.test",
            "role" => "dev"
          }
        }
      })

      result =
        find_in_output(ctx, fn r -> r["id"] == 42 and is_map(r["result"]) end, 2_000)

      assert result, "expected tool result for id=42"
      text = get_in(result, ["result", "content", Access.at(0), "text"])
      assert %{"hello" => "async my name is Stdio Alice"} = JSON.decode!(text)
    end
  end

  describe "duplicate request dedup" do
    test "duplicate tools/call while an async tool holds the in-flight claim is rejected" do
      # An async tool returns `{:noreply, session}` and does its
      # work in a spawned Task. The session keeps the in-flight
      # claim held until `Session.respond/2` — so a duplicate
      # `tools/call` that arrives in that window is visible to
      # the dispatch loop and gets rejected.
      ctx = start_stdio()
      initialize_with_elicitation(ctx)

      # First call — returns {:noreply, _} after spawning a Task;
      # the Task will eventually elicit. The in-flight claim is
      # held for the entire duration.
      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 7,
        method: "tools/call",
        params: %{name: "async_elicit_tool", arguments: %{}}
      })

      # Wait until we see the elicitation on the wire — proves
      # the Task is running and the in-flight claim is live.
      elicit =
        find_in_output(ctx, fn r -> r["method"] == "elicitation/create" end, 2_000)

      assert elicit, "expected elicitation/create from first call"

      # Duplicate with the same id while the original is in flight
      send_request(ctx, %{
        jsonrpc: "2.0",
        id: 7,
        method: "tools/call",
        params: %{name: "async_elicit_tool", arguments: %{}}
      })

      dup_error =
        find_in_output(ctx, fn r -> r["id"] == 7 and is_map(r["error"]) end, 2_000)

      assert dup_error, "expected duplicate-request error for second call"
      assert dup_error["error"]["code"] == -32600
      assert dup_error["error"]["message"] =~ "Duplicate"

      # Unblock the first call so the session shuts down cleanly
      send_request(ctx, %{
        jsonrpc: "2.0",
        id: elicit["id"],
        result: %{
          "action" => "accept",
          "content" => %{
            "name" => "Stdio Alice",
            "email" => "alice@stdio.test",
            "role" => "dev"
          }
        }
      })

      _ = find_in_output(ctx, fn r -> r["id"] == 7 and is_map(r["result"]) end, 2_000)
    end
  end

  # Polls the mock output until `predicate` matches one of the
  # parsed responses or the timeout fires.
  defp find_in_output(ctx, predicate, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    find_in_output_loop(ctx, predicate, deadline)
  end

  defp find_in_output_loop(ctx, predicate, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      nil
    else
      try do
        output = MockIO.await_output(ctx.output, remaining)

        case Enum.find(parse_responses(output), predicate) do
          nil -> find_in_output_loop(ctx, predicate, deadline)
          found -> found
        end
      catch
        :exit, _ -> nil
      end
    end
  end
end

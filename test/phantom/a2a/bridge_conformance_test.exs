defmodule Phantom.A2A.BridgeConformanceTest.Tools do
  require Phantom.Tool, as: Tool

  def silent(_params, session), do: {:reply, Tool.response([]), session}

  def working(_params, session) do
    {:reply, Phantom.A2A.BridgeConformanceTest.Router.working("w1"), session}
  end
end

defmodule Phantom.A2A.BridgeConformanceTest.Fallback do
  use Phantom.A2A.Agent, name: "Fallback", description: "Keeps its own tasks"

  alias Phantom.A2A.{Message, Task, TaskStatus}

  def handle_message(%Message{task_id: id} = message, ctx) when is_binary(id) do
    {:reply, Message.agent("continued #{message.task_id}"), ctx}
  end

  def handle_message(_message, ctx) do
    {:reply, Task.submitted(ctx, status: %TaskStatus{state: :input_required}), ctx}
  end

  def get_task("fb-" <> _ = id, _ctx) do
    {:ok, %Task{id: id, context_id: "fb-ctx", status: %TaskStatus{state: :input_required}}}
  end

  def get_task(_id, _ctx), do: {:error, :not_found}

  def cancel_task(task, _ctx), do: {:ok, %{task | status: %TaskStatus{state: :canceled}}}
end

defmodule Phantom.A2A.BridgeConformanceTest.Router do
  use Phantom.Router, name: "Bridge conformance", vsn: "1.0"

  alias Phantom.A2A.BridgeConformanceTest.{Fallback, Tools}

  tool :silent, Tools, description: "Answers with nothing", input_schema: %{}
  tool :working, Tools, description: "Keeps working", input_schema: %{}

  agent "tools", Phantom.A2A.Bridge
  agent "fallback", Phantom.A2A.Bridge, fallback: Fallback

  def working(id) do
    Phantom.Tasks.new(id: id, created_at: DateTime.utc_now(), status: :working)
  end

  def get_task("w" <> _ = id, _session), do: {:ok, working(id)}
  def get_task(_id, _session), do: {:error, :not_found}
end

defmodule Phantom.A2A.BridgeConformanceTest do
  # Phantom.Tracker is deliberately not running: its name is global.
  use ExUnit.Case, async: false

  alias Phantom.A2A.BridgeConformanceTest.Router

  @pubsub Phantom.A2A.BridgeConformanceTest.PubSub

  setup_all do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    :ok
  end

  defp rpc(path, method, params, opts \\ []) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    :post
    |> Plug.Test.conn(path, JSON.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("a2a-version", "1.0")
    |> Phantom.A2A.Plug.call(Phantom.A2A.Plug.init([router: Router, pubsub: @pubsub] ++ opts))
    |> Map.fetch!(:resp_body)
    |> JSON.decode!()
  end

  defp data_message(data, extra \\ %{}) do
    Map.merge(
      %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"data" => data}]},
      extra
    )
  end

  defp text_message(text, extra) do
    Map.merge(
      %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => text}]},
      extra
    )
  end

  test "tool arguments must be an object" do
    for arguments <- ["s", [1], 5] do
      message = data_message(%{"tool" => "silent", "arguments" => arguments})

      assert %{"error" => %{"code" => -32602}} =
               rpc("/tools", "SendMessage", %{"message" => message})
    end
  end

  test "a tool that answers with nothing still sends a part" do
    assert %{"result" => %{"message" => %{"parts" => [_ | _]}}} =
             rpc("/tools", "SendMessage", %{"message" => data_message(%{"tool" => "silent"})})
  end

  test "a client's contextId is refused when a tool may start a task in its own context" do
    message = data_message(%{"tool" => "working"}, %{"contextId" => "mine"})

    assert %{"error" => %{"code" => -32602}} =
             rpc("/tools", "SendMessage", %{"message" => message})
  end

  test "without Phantom.Tracker, a stream can't follow an unfinished MCP task" do
    params = %{"message" => data_message(%{"tool" => "working"})}

    assert %{"error" => %{"code" => -32004}} = rpc("/tools", "SendStreamingMessage", params)
    assert %{"error" => %{"code" => -32004}} = rpc("/tools", "SubscribeToTask", %{"id" => "w1"})
  end

  test "without Phantom.Tracker, SendMessage still answers at the deadline" do
    params = %{"message" => data_message(%{"tool" => "working"})}

    assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_WORKING"}}}} =
             rpc("/tools", "SendMessage", params, blocking_timeout: 20, poll_interval: 1)
  end

  describe "the fallback agent's tasks" do
    test "can be fetched" do
      assert %{"result" => %{"id" => "fb-1", "contextId" => "fb-ctx"}} =
               rpc("/fallback", "GetTask", %{"id" => "fb-1"})
    end

    test "can be canceled" do
      assert %{"result" => %{"status" => %{"state" => "TASK_STATE_CANCELED"}}} =
               rpc("/fallback", "CancelTask", %{"id" => "fb-1"})
    end

    test "can be continued" do
      message = text_message("more", %{"taskId" => "fb-1"})

      assert %{"result" => %{"message" => %{"parts" => [%{"text" => "continued fb-1"}]}}} =
               rpc("/fallback", "SendMessage", %{"message" => message})
    end

    test "are not found without a fallback" do
      assert %{"error" => %{"code" => -32001}} = rpc("/tools", "GetTask", %{"id" => "fb-1"})
    end
  end
end

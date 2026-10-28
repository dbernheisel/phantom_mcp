defmodule Phantom.A2A.TestHelpersTest.Echo do
  use Phantom.A2A.Agent, name: "Echo", description: "Echoes"

  alias Phantom.A2A.{Message, Part, Task, TaskStatus}

  def handle_message(%Message{parts: [%Part{text: "task"}]}, ctx),
    do: {:reply, Task.submitted(ctx, status: %TaskStatus{state: :completed}), ctx}

  def handle_message(%Message{parts: [%Part{text: text}]}, ctx),
    do: {:reply, Message.agent("#{ctx.assigns.user}: #{text}"), ctx}

  def get_task(id, _ctx),
    do: {:ok, %Task{id: id, context_id: "c", status: %TaskStatus{state: :working}}}

  def cancel_task(task, _ctx), do: {:ok, %{task | status: %TaskStatus{state: :canceled}}}
end

defmodule Phantom.A2A.TestHelpersTest.Router do
  use Phantom.Router, name: "Helpers", vsn: "1.0"

  agent "echo", Phantom.A2A.TestHelpersTest.Echo

  def connect(session, conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> user] -> {:ok, Phantom.Session.assign(session, user: user)}
      [] -> {:unauthorized, %{method: "Bearer"}}
    end
  end
end

defmodule Phantom.A2A.TestHelpersTest do
  use ExUnit.Case, async: true

  import Phantom.A2A.Test

  alias Phantom.A2A.TestHelpersTest.Router

  @auth [headers: [{"authorization", "Bearer alice"}]]

  test "get_card/3" do
    assert %{
             "name" => "Echo",
             "supportedInterfaces" => [%{"url" => "http://www.example.com/echo"} | _]
           } =
             get_card(Router, "echo")
  end

  test "send_message/4 with text or a message" do
    assert {:message, %{"parts" => [%{"text" => "alice: hi"}]}} =
             send_message(Router, "echo", "hi", @auth)

    message = Phantom.A2A.Message.user("yo", context_id: "ctx")

    assert {:message, %{"contextId" => "ctx", "parts" => [%{"text" => "alice: yo"}]}} =
             send_message(Router, "echo", message, @auth)

    assert {:task, %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}} =
             send_message(Router, "echo", "task", @auth)
  end

  test "errors" do
    assert {:error, %{"code" => -32600, "message" => "Unauthorized"}} =
             send_message(Router, "echo", "hi")

    assert {:error, %{"code" => -32600, "message" => "Not found"}} =
             send_message(Router, "nope", "hi", @auth)
  end

  test "get_task/4 and cancel_task/4" do
    assert {:ok, %{"id" => "t1", "status" => %{"state" => "TASK_STATE_WORKING"}}} =
             get_task(Router, "echo", "t1", @auth)

    assert {:ok, %{"status" => %{"state" => "TASK_STATE_CANCELED"}}} =
             cancel_task(Router, "echo", "t1", @auth)
  end
end

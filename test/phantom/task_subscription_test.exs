defmodule Phantom.TaskSubscriptionTest.Router do
  use Phantom.Router, name: "Task subscription test"

  def connect(session, %Plug.Conn{} = conn) do
    user_id = conn |> Plug.Conn.get_req_header("x-user-id") |> List.first()
    {:ok, Phantom.Session.assign(session, user_id: user_id)}
  end

  def connect(session, _context), do: {:ok, session}

  def get_task(task_id, session) do
    owners = :persistent_term.get({__MODULE__, :owners}, %{})

    status = :persistent_term.get({__MODULE__, :status}, :working)

    if Map.get(owners, task_id) == session.assigns[:user_id],
      do: {:ok, task(task_id, status)},
      else: {:error, :not_found}
  end

  def task(id, status \\ :working) do
    attrs = [id: id, status: status, created_at: ~U[2025-11-25 10:30:00Z]]

    if status == :completed,
      do: Phantom.Tasks.new([result: %{content: [%{type: "text", text: "Done"}]}] ++ attrs),
      else: Phantom.Tasks.new(attrs)
  end
end

defmodule Phantom.TaskSubscriptionTest.CustomRouter do
  use Phantom.Router, name: "Task subscription custom authorization test"

  def get_task(id, _session), do: {:ok, Phantom.TaskSubscriptionTest.Router.task(id)}

  def authorize_task_subscriptions(task_ids, _session) do
    case :persistent_term.get({__MODULE__, :return}, :all) do
      :raise -> raise "authorization failed"
      :invalid -> %{allowed: task_ids}
      :all -> task_ids
      allowed -> allowed
    end
  end
end

defmodule Phantom.TaskSubscriptionTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  import Phantom.TestDispatcher
  import Plug.Conn

  alias Phantom.TaskSubscriptionTest.CustomRouter
  alias Phantom.TaskSubscriptionTest.Router
  alias Phantom.Session

  @tasks_ext "io.modelcontextprotocol/tasks"

  setup do
    start_supervised({Phoenix.PubSub, name: Test.PubSub})
    start_supervised({Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]})
    Phantom.Cache.register(Router)
    Phantom.Cache.register(CustomRouter)
    :persistent_term.put({Router, :owners}, %{"alice-1" => "alice", "bob-1" => "bob"})

    on_exit(fn ->
      :persistent_term.erase({Router, :owners})
      :persistent_term.erase({Router, :status})
      :persistent_term.erase({CustomRouter, :return})
    end)

    :ok
  end

  describe "authorize_task_subscriptions" do
    test "defaults to the tasks get_task/2 returns" do
      session = Session.new("s", router: Router) |> Session.assign(user_id: "alice")

      assert Phantom.Router.authorize_task_subscriptions(Router, ["alice-1", "bob-1"], session) ==
               ["alice-1"]
    end

    test "keeps only requested IDs from a custom callback" do
      session = Session.new("s", router: CustomRouter)
      :persistent_term.put({CustomRouter, :return}, ["a", "not-requested"])

      assert Phantom.Router.authorize_task_subscriptions(CustomRouter, ["a", "b"], session) ==
               ["a"]
    end

    test "invalid callback results and exceptions fail closed" do
      session = Session.new("s", router: CustomRouter)

      :persistent_term.put({CustomRouter, :return}, :invalid)
      assert Phantom.Router.authorize_task_subscriptions(CustomRouter, ["a"], session) == []

      :persistent_term.put({CustomRouter, :return}, nil)
      assert Phantom.Router.authorize_task_subscriptions(CustomRouter, ["a"], session) == []

      :persistent_term.put({CustomRouter, :return}, :raise)

      assert capture_log(fn ->
               assert Phantom.Router.authorize_task_subscriptions(CustomRouter, ["a"], session) ==
                        []
             end) =~ "failed closed"
    end
  end

  describe "subscriptions/listen with taskIds" do
    test "acknowledges and tracks only authorized tasks" do
      stream_pid = listen(["alice-1", "bob-1"], "alice")

      assert_notify(%{
        method: "notifications/subscriptions/acknowledged",
        params: %{notifications: %{"taskIds" => ["alice-1"]}}
      })

      wait_for_task_listeners(["alice-1"])
      tracked = Enum.map(Phantom.Tracker.list_task_listeners(), &elem(&1, 0))
      refute "bob-1" in tracked

      Session.finish(stream_pid)
    end

    test "sends notifications/tasks with the stored task" do
      stream_pid = listen(["alice-1", "bob-1"], "alice")
      assert_notify(%{method: "notifications/subscriptions/acknowledged"})
      wait_for_task_listeners(["alice-1"])

      :persistent_term.put({Router, :status}, :completed)
      task = Router.task("alice-1", :completed)
      # A stale copy still sends the stored task.
      Phantom.Tracker.notify_task_updated(Router.task("alice-1", :working))
      Phantom.Tracker.notify_task_updated("bob-1")

      expected = Phantom.Tasks.to_json(task)

      assert_notify(%{
        method: "notifications/tasks",
        params: %{_meta: %{"io.modelcontextprotocol/subscriptionId" => "listen:0"}} = params
      })

      assert Map.delete(params, :_meta) == expected

      refute_receive {:response, nil, "message",
                      %{method: "notifications/tasks", params: %{taskId: "bob-1"}}}

      Session.finish(stream_pid)
    end

    test "accepts a task ID" do
      stream_pid = listen(["alice-1"], "alice")
      assert_notify(%{method: "notifications/subscriptions/acknowledged"})
      wait_for_task_listeners(["alice-1"])

      Phantom.Tracker.notify_task_updated("alice-1")

      assert_notify(%{
        method: "notifications/tasks",
        params: %{taskId: "alice-1", status: "working"}
      })

      Session.finish(stream_pid)
    end

    test "stops following a task once it finishes" do
      stream_pid = listen(["alice-1"], "alice")
      assert_notify(%{method: "notifications/subscriptions/acknowledged"})
      wait_for_task_listeners(["alice-1"])

      :persistent_term.put({Router, :status}, :completed)
      Phantom.Tracker.notify_task_updated("alice-1")
      assert_notify(%{method: "notifications/tasks", params: %{status: "completed"}})

      wait_for_no_task_listeners("alice-1")
      Session.finish(stream_pid)
    end

    test "re-authorizes before each notification" do
      stream_pid = listen(["alice-1"], "alice")
      assert_notify(%{method: "notifications/subscriptions/acknowledged"})
      wait_for_task_listeners(["alice-1"])

      :persistent_term.put({Router, :owners}, %{"alice-1" => "bob"})
      Phantom.Tracker.notify_task_updated(Router.task("alice-1", :completed))

      refute_receive {:response, nil, "message", %{method: "notifications/tasks"}}

      Session.finish(stream_pid)
    end

    test "ignores an empty taskIds list when the request did not declare the extension" do
      stream_pid = listen([], "alice", %{})
      assert_notify(%{method: "notifications/subscriptions/acknowledged"})
      Session.finish(stream_pid)
    end

    test "is a missing capability error when the request did not declare the extension" do
      listen(["alice-1"], "alice", %{})

      assert_receive {:conn, conn}
      error = JSON.decode!(conn.resp_body)["error"]
      assert error["code"] == -32021
      assert error["data"] == %{"requiredCapabilities" => %{"extensions" => %{@tasks_ext => %{}}}}
    end
  end

  defp listen(task_ids, user_id, capabilities \\ %{"extensions" => %{@tasks_ext => %{}}}) do
    :post
    |> Plug.Test.conn("/mcp", %{
      "jsonrpc" => "2.0",
      "id" => "listen:0",
      "method" => "subscriptions/listen",
      "params" => %{
        "notifications" => %{"taskIds" => task_ids},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => capabilities
        }
      }
    })
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", "subscriptions/listen")
    |> call(%{
      router: Router,
      before_call: &put_req_header(&1, "x-user-id", user_id)
    })
  end

  defp wait_for_task_listeners(expected, attempts \\ 50)

  defp wait_for_task_listeners(expected, attempts) when attempts > 0 do
    actual = Phantom.Tracker.list_task_listeners() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    if MapSet.subset?(MapSet.new(expected), actual) do
      :ok
    else
      Process.sleep(10)
      wait_for_task_listeners(expected, attempts - 1)
    end
  end

  defp wait_for_task_listeners(expected, 0),
    do: flunk("task listeners were not tracked: #{inspect(expected)}")

  defp wait_for_no_task_listeners(task_id, attempts \\ 50)

  defp wait_for_no_task_listeners(task_id, attempts) when attempts > 0 do
    if Enum.any?(Phantom.Tracker.list_task_listeners(), &match?({^task_id, _}, &1)) do
      Process.sleep(10)
      wait_for_no_task_listeners(task_id, attempts - 1)
    else
      :ok
    end
  end

  defp wait_for_no_task_listeners(task_id, 0),
    do: flunk("task listener was still tracked: #{inspect(task_id)}")
end

defmodule Phantom.A2A.BridgeTasksTest.Tools do
  require Phantom.Tool, as: Tool

  @table Phantom.A2A.BridgeTasksTest

  def export(_params, session) do
    if Phantom.Session.tasks_supported?(session) do
      task = new(status: :working, status_message: "Exporting")
      {:reply, task, session}
    else
      {:reply, Tool.text("exported now"), session}
    end
  end

  # Keeps working until the test finishes it; see `finishing_slow_export/1`.
  def slow_export(_params, session) do
    task = new(status: :working, status_message: "Exporting")
    :ets.insert(@table, {{:slow, task.id}, true})
    {:reply, task, session}
  end

  def confirm(_params, session) do
    elicit =
      Phantom.Elicit.form(%{
        message: "Sure?",
        requested_schema: [%{name: "ok", type: :boolean, required: true}]
      })

    {:reply, new(status: :input_required, input_requests: %{"ok" => elicit}), session}
  end

  defp new(attrs) do
    task =
      Phantom.Tasks.new(
        [id: Phantom.Tasks.generate_id(), created_at: DateTime.utc_now()] ++ attrs
      )

    :ets.insert(@table, {task.id, task})
    task
  end

  # Asks for input; the answer's work finishes just after the bridge reads it.
  def racy_confirm(_params, session) do
    elicit =
      Phantom.Elicit.form(%{
        message: "Sure?",
        requested_schema: [%{name: "ok", type: :boolean, required: true}]
      })

    task = new(status: :input_required, input_requests: %{"ok" => elicit})
    :ets.insert(@table, {{:racy, task.id}, :waiting})
    {:reply, task, session}
  end

  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, task}] ->
        finish_if_racing(id)
        report_fetch(id)
        {:ok, task}

      [] ->
        {:error, :not_found}
    end
  end

  # Tells the test when a request that listens for the task's updates fetches it.
  defp report_fetch(id) do
    me = self()

    with [_slow] <- :ets.lookup(@table, {:slow, id}),
         [{:observer, pid}] <- :ets.lookup(@table, :observer),
         true <- Enum.any?(Phantom.Tracker.list_task_listeners(), &match?({^id, %{pid: ^me}}, &1)) do
      send(pid, {:fetched, id})
    end
  end

  defp finish_if_racing(id) do
    case :ets.lookup(@table, {:racy, id}) do
      [{_key, :answered}] ->
        :ets.delete(@table, {:racy, id})
        finish(id, "Finished in the gap")

      _other ->
        :ok
    end
  end

  def answered(id) do
    if :ets.member(@table, {:racy, id}) do
      :ets.insert(@table, {{:racy, id}, :answered})
      {:ok, task} = lookup(id)
      put(%{task | status: :working, input_requests: %{}})
      true
    end
  end

  defp lookup(id) do
    [{^id, task}] = :ets.lookup(@table, id)
    {:ok, task}
  end

  def put(task), do: :ets.insert(@table, {task.id, task})

  def finish(id, text) do
    {:ok, task} = lookup(id)
    put(%{task | status: :completed, input_requests: %{}, result: Tool.response(Tool.text(text))})
  end
end

defmodule Phantom.A2A.BridgeTasksTest.Router do
  use Phantom.Router, name: "Tasks", vsn: "1.0"

  alias Phantom.A2A.BridgeTasksTest.Tools

  tool :export, Tools, description: "Export a report", input_schema: %{}
  tool :confirm, Tools, description: "Ask before acting", input_schema: %{}
  tool :slow_export, Tools, description: "Export a report later", input_schema: %{}
  tool :racy_confirm, Tools, description: "Ask, then finish quickly", input_schema: %{}

  agent "tools", Phantom.A2A.Bridge

  def get_task(id, _session), do: Tools.get(id)

  def update_task(task, responses, _session) do
    Tools.answered(task.id) ||
      Tools.finish(task.id, "confirmed: #{responses["ok"]["content"]["ok"]}")

    :ok
  end

  def cancel_task(task, _session) do
    Tools.put(%{task | status: :cancelled, status_message: "Stopped"})
    :ok
  end
end

defmodule Phantom.A2A.BridgeTasksTest.NoTasksRouter do
  use Phantom.Router, name: "No tasks"

  tool :export, Phantom.A2A.BridgeTasksTest.Tools,
    description: "Export a report",
    input_schema: %{}

  agent "tools", Phantom.A2A.Bridge
end

defmodule Phantom.A2A.BridgeTasksTest do
  use ExUnit.Case, async: false

  import Phantom.A2A.Test

  alias Phantom.A2A.{Message, Part}
  alias Phantom.A2A.BridgeTasksTest.{NoTasksRouter, Router, Tools}

  setup_all do
    start_supervised!({Agent, fn -> :ets.new(__MODULE__, [:named_table, :public, :set]) end})
    start_supervised!({Phoenix.PubSub, name: Phantom.A2A.BridgeTasksTest.PubSub})

    start_supervised!(
      {Phantom.Tracker,
       [name: Phantom.Tracker, pubsub_server: Phantom.A2A.BridgeTasksTest.PubSub]}
    )

    :ok
  end

  defp call(router, tool),
    do: send_message(router, "tools", Message.user([Part.data(%{"tool" => tool})]))

  test "call_tool/4 with tasks: true returns the tool's task" do
    session = Phantom.Session.new(nil, router: Router)

    assert {:ok, %Phantom.Tasks{status: :working}} =
             Phantom.Router.call_tool(session, :export, %{}, tasks: true)

    assert {:ok, %{content: [%{text: "exported now"}]}} =
             Phantom.Router.call_tool(session, :export)
  end

  test "a tool's MCP task becomes an A2A task, in its own context" do
    assert {:task,
            %{
              "id" => id,
              "contextId" => id,
              "status" => %{
                "state" => "TASK_STATE_WORKING",
                "message" => %{"role" => "ROLE_AGENT", "parts" => [%{"text" => "Exporting"}]}
              }
            }} = call(Router, "export")

    Tools.finish(id, "Report ready")

    assert {:ok,
            %{
              "status" => %{"state" => "TASK_STATE_COMPLETED"},
              "artifacts" => [
                %{"artifactId" => "result", "parts" => [%{"text" => "Report ready"}]}
              ]
            }} = get_task(Router, "tools", id)
  end

  test "input requests are answered with a message on the task" do
    assert {:task,
            %{
              "id" => id,
              "status" => %{
                "state" => "TASK_STATE_INPUT_REQUIRED",
                "message" => %{"parts" => parts}
              }
            }} = call(Router, "confirm")

    assert [%{"data" => %{"inputRequests" => %{"ok" => %{"params" => %{"message" => "Sure?"}}}}}] =
             Enum.filter(parts, &Map.has_key?(&1, "data"))

    answer =
      Message.user(
        [
          Part.data(%{
            "inputResponses" => %{"ok" => %{"action" => "accept", "content" => %{"ok" => true}}}
          })
        ],
        task_id: id,
        context_id: id
      )

    assert {:task,
            %{
              "status" => %{"state" => "TASK_STATE_COMPLETED"},
              "artifacts" => [%{"parts" => [%{"text" => "confirmed: true"}]}]
            }} =
             send_message(Router, "tools", answer)
  end

  test "canceling goes to the router" do
    {:task, %{"id" => id}} = call(Router, "export")

    assert {:ok,
            %{
              "status" => %{
                "state" => "TASK_STATE_CANCELED",
                "message" => %{"parts" => [%{"text" => "Stopped"}]}
              }
            }} =
             cancel_task(Router, "tools", id)
  end

  test "unknown tasks are not found" do
    assert {:error, %{"code" => -32001}} = get_task(Router, "tools", "nope")
  end

  test "without the router's task callbacks, tools answer at once" do
    assert {:message, %{"parts" => [%{"text" => "exported now"}]}} = call(NoTasksRouter, "export")
  end

  describe "following a task the tool updates" do
    @plug_opts [
      router: Router,
      pubsub: Phantom.A2A.BridgeTasksTest.PubSub,
      blocking_timeout: 2_000
    ]

    defp rpc(method, params) do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

      :post
      |> Plug.Test.conn("/tools", JSON.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("a2a-version", "1.0")
      |> Phantom.A2A.Plug.call(Phantom.A2A.Plug.init(@plug_opts))
    end

    defp slow_export,
      do: %{"message" => Message.to_json(Message.user([Part.data(%{"tool" => "slow_export"})]))}

    # Runs the request, and finishes the slow export as a job would once the
    # request is following it.
    defp finishing_slow_export(request) do
      :ets.insert(__MODULE__, {:observer, self()})
      pending = Task.async(request)

      assert_receive {:fetched, id}, 2_000
      Tools.finish(id, "Slow report ready")
      Phantom.Tracker.notify_task_updated(id)

      Task.await(pending)
    end

    defp events(conn) do
      for "id: " <> event <- String.split(conn.resp_body, "\n\n", trim: true) do
        [_id, "data: " <> data] = String.split(event, "\n")
        JSON.decode!(data)["result"]
      end
    end

    test "SendMessage waits for notify_task_updated/1" do
      assert %{
               "result" => %{
                 "task" => %{
                   "status" => %{"state" => "TASK_STATE_COMPLETED"},
                   "artifacts" => [%{"parts" => [%{"text" => "Slow report ready"}]}]
                 }
               }
             } =
               JSON.decode!(
                 finishing_slow_export(fn -> rpc("SendMessage", slow_export()) end).resp_body
               )
    end

    test "SendStreamingMessage streams the task's changes as update events" do
      assert [
               %{"task" => %{"id" => id, "status" => %{"state" => "TASK_STATE_WORKING"}}},
               %{
                 "artifactUpdate" => %{
                   "taskId" => id,
                   "contextId" => id,
                   "lastChunk" => true,
                   "artifact" => %{"parts" => [%{"text" => "Slow report ready"}]}
                 }
               },
               %{
                 "statusUpdate" => %{
                   "taskId" => id,
                   "contextId" => id,
                   "status" => %{"state" => "TASK_STATE_COMPLETED"}
                 }
               }
             ] =
               events(finishing_slow_export(fn -> rpc("SendStreamingMessage", slow_export()) end))
    end

    test "a task that finishes before the request listens isn't waited on" do
      {:task, %{"id" => id}} = call(Router, "racy_confirm")

      answer =
        Message.user(
          [Part.data(%{"inputResponses" => %{"ok" => %{"action" => "accept"}}})],
          task_id: id
        )

      {elapsed, conn} =
        :timer.tc(fn -> rpc("SendMessage", %{"message" => Message.to_json(answer)}) end)

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               JSON.decode!(conn.resp_body)

      assert elapsed < 1_000_000
    end

    test "SubscribeToTask streams the task's changes as update events" do
      {:task, %{"id" => id}} = call(Router, "slow_export")

      assert [
               %{"task" => %{"status" => %{"state" => "TASK_STATE_WORKING"}}},
               %{"artifactUpdate" => %{"artifact" => %{"artifactId" => "result"}}},
               %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}
             ] = events(finishing_slow_export(fn -> rpc("SubscribeToTask", %{"id" => id}) end))

      assert [] = Phantom.Tracker.list_task_listeners()
    end

    test "a missing task leaves nothing listening" do
      assert %{"error" => %{"code" => -32001}} =
               JSON.decode!(rpc("SubscribeToTask", %{"id" => "nope"}).resp_body)

      assert [] = Phantom.Tracker.list_task_listeners()
    end
  end
end

defmodule Phantom.TasksDispatchTest do
  use ExUnit.Case, async: true

  alias Phantom.Session

  @tasks_ext "io.modelcontextprotocol/tasks"

  defmodule Router do
    use Phantom.Router, name: "Tasks", vsn: "1.0"

    def get_task("expired", _session), do: {:error, :expired}
    def get_task("broken", _session), do: {:error, Phantom.Request.internal_error("broken")}

    def get_task(id, %{assigns: %{owner: "alice"}}) when id in ~w[working input rejecting],
      do: {:ok, task(id)}

    def get_task(_task_id, _session), do: {:error, :not_found}

    def update_task(%{id: "rejecting"}, _responses, _session),
      do: {:error, Phantom.Request.invalid_params(%{inputResponses: "rejected"})}

    def update_task(task, responses, session) do
      send(session.assigns.test_pid, {:update_task, task.id, responses})
      :ok
    end

    def cancel_task(task, session) do
      send(session.assigns.test_pid, {:cancel_task, task.id})
      :ok
    end

    def task("working"),
      do: Phantom.Tasks.new(id: "working", status: :working, created_at: ~U[2025-11-25 10:30:00Z])

    def task(id) when id in ~w[input rejecting] do
      Phantom.Tasks.new(
        id: id,
        status: :input_required,
        created_at: ~U[2025-11-25 10:30:00Z],
        input_requests: %{
          "name" => %{method: "elicitation/create", params: %{mode: "form", message: "Name?"}},
          "age" => %{method: "elicitation/create", params: %{mode: "form", message: "Age?"}}
        }
      )
    end

    tool :always_task, description: "Always answers with a task"
    tool :input_task, description: "Answers with a task that already needs input"

    def input_task(_params, session), do: {:reply, task("input"), session}

    def always_task(_params, session) do
      {:reply,
       Phantom.Tasks.new(
         id: "task-1",
         status: :working,
         created_at: ~U[2025-11-25 10:30:00Z],
         ttl_ms: 60_000,
         poll_interval_ms: 5_000
       ), session}
    end
  end

  defmodule NoTasksRouter do
    use Phantom.Router, name: "NoTasks", vsn: "1.0"
  end

  defmodule BadRouter do
    use Phantom.Router, name: "Bad", vsn: "1.0"

    def get_task("plain-map", _session), do: {:ok, %{id: "plain-map"}}
    def get_task(id, _session), do: {:ok, Phantom.TasksDispatchTest.Router.task(id)}

    def update_task(task, _responses, _session), do: {:ok, task}
  end

  defmodule GetOnlyRouter do
    use Phantom.Router, name: "GetOnly", vsn: "1.0"

    def get_task(id, _session), do: {:ok, Phantom.TasksDispatchTest.Router.task(id)}
  end

  import Phantom.Test

  setup do
    Phantom.Test.start(router: Router)
    Phantom.Test.start(router: NoTasksRouter)
    Phantom.Test.start(router: GetOnlyRouter)
    Phantom.Test.start(router: BadRouter)
    :ok
  end

  defp tasks_capabilities, do: %{extensions: %{@tasks_ext => %{}}}

  defp session(router \\ Router, opts \\ []) do
    build_session(
      router,
      Keyword.merge(
        [
          protocol_version: "2026-07-28",
          client_capabilities: tasks_capabilities(),
          assigns: %{owner: "alice", test_pid: self()}
        ],
        opts
      )
    )
  end

  defp dispatch(session, method, params \\ %{}) do
    request = %{build_request(method, params: params) | meta: session.request.meta}
    session = %{session | pid: self(), request: request}
    session.router.dispatch_method([method, params, request, session])
  end

  describe "Session.tasks_supported?/1" do
    test "is true when the request declares the extension" do
      assert Session.tasks_supported?(session())
    end

    test "is false when the request does not declare the extension" do
      refute Session.tasks_supported?(session(Router, client_capabilities: %{}))
    end

    test "is false under a legacy protocol" do
      refute Session.tasks_supported?(build_session(Router))
    end
  end

  describe "server/discover" do
    test "advertises the extension when the router implements get_task/2" do
      assert {:reply, %{capabilities: %{extensions: %{@tasks_ext => %{}}}}, _} =
               dispatch(session(), "server/discover")
    end

    test "does not advertise the extension otherwise" do
      assert {:reply, %{capabilities: capabilities}, _} =
               dispatch(session(NoTasksRouter), "server/discover")

      refute get_in(capabilities, [:extensions, @tasks_ext])
    end
  end

  describe "tools/call returning a task" do
    test "responds with a CreateTaskResult" do
      assert call_tool(session(), :always_task) == %{
               resultType: "task",
               taskId: "task-1",
               status: "working",
               createdAt: "2025-11-25T10:30:00Z",
               lastUpdatedAt: "2025-11-25T10:30:00Z",
               ttlMs: 60_000,
               pollIntervalMs: 5_000
             }
    end

    test "leaves status-specific fields out of the CreateTaskResult" do
      result = call_tool(session(), :input_task)
      assert %{resultType: "task", taskId: "input", status: "input_required"} = result
      refute Map.has_key?(result, :inputRequests)
    end

    test "keeps resultType task through result normalization" do
      request = %{build_request("tools/call") | meta: session().request.meta}

      assert %{resultType: "task"} =
               Phantom.Request.normalize_result(%{resultType: "task", taskId: "t"}, request)
    end

    test "is a missing capability error when the request did not declare the extension" do
      assert {:jsonrpc_error, error} =
               call_tool(session(Router, client_capabilities: %{}), :always_task)

      assert error == %{
               code: -32021,
               message: "Missing required client capability",
               data: %{requiredCapabilities: %{extensions: %{@tasks_ext => %{}}}}
             }
    end

    test "is a missing capability error under a legacy protocol" do
      assert {:jsonrpc_error, %{code: -32021}} = call_tool(build_session(Router), :always_task)
    end
  end

  @not_found %{code: -32602, message: "Failed to retrieve task: Task not found"}

  describe "tasks/get" do
    test "returns the task" do
      assert {:reply, result, _} = dispatch(session(), "tasks/get", %{"taskId" => "working"})
      assert result == Phantom.Tasks.to_json(Router.task("working"))
    end

    test "inlines outstanding input requests" do
      assert {:reply, %{status: "input_required", inputRequests: %{"name" => _, "age" => _}}, _} =
               dispatch(session(), "tasks/get", %{"taskId" => "input"})
    end

    test "is not found when get_task/2 denies the caller" do
      session = session(Router, assigns: %{owner: "mallory", test_pid: self()})

      assert {:error, @not_found, _} = dispatch(session, "tasks/get", %{"taskId" => "working"})
    end

    test "is not found for an unknown task" do
      assert {:error, @not_found, _} = dispatch(session(), "tasks/get", %{"taskId" => "nope"})
    end

    test "reports an expired task" do
      assert {:error, %{code: -32602, message: "Failed to retrieve task: Task has expired"}, _} =
               dispatch(session(), "tasks/get", %{"taskId" => "expired"})
    end

    test "passes through a JSON-RPC error from get_task/2" do
      assert {:error, %{code: -32603, message: "broken"}, _} =
               dispatch(session(), "tasks/get", %{"taskId" => "broken"})
    end

    test "raises a clear error when get_task/2 returns an unexpected value" do
      assert_raise ArgumentError, ~r/get_task\/2/, fn ->
        dispatch(session(BadRouter), "tasks/get", %{"taskId" => "plain-map"})
      end
    end

    test "is method not found under a legacy protocol" do
      request = build_request("tasks/get", params: %{"taskId" => "working"})
      session = %{build_session(Router) | pid: self(), request: request}

      assert {:error, %{code: -32601}, _} =
               Router.dispatch_method(["tasks/get", request.params, request, session])
    end

    test "requires a taskId" do
      assert {:error, %{code: -32602}, _} = dispatch(session(), "tasks/get", %{})
    end

    test "is a missing capability error when the request did not declare the extension" do
      assert {:error,
              %{code: -32021, data: %{requiredCapabilities: %{extensions: %{@tasks_ext => %{}}}}},
              _} =
               dispatch(session(Router, client_capabilities: %{}), "tasks/get", %{
                 "taskId" => "working"
               })
    end

    test "is method not found when the router does not implement tasks" do
      assert {:error, %{code: -32601}, _} =
               dispatch(session(NoTasksRouter), "tasks/get", %{"taskId" => "working"})
    end

    test "other tasks methods are method not found" do
      assert {:error, %{code: -32601}, _} = dispatch(session(), "tasks/list", %{})
    end
  end

  describe "tasks/update" do
    test "passes only outstanding input responses to update_task/3" do
      params = %{
        "taskId" => "input",
        "inputResponses" => %{
          "name" => %{"action" => "accept", "content" => %{"name" => "Luca"}},
          "unknown" => %{"action" => "accept"}
        }
      }

      assert {:reply, %{}, _} = dispatch(session(), "tasks/update", params)

      assert_received {:update_task, "input",
                       %{"name" => %{"action" => "accept", "content" => %{"name" => "Luca"}}} =
                         responses}

      refute Map.has_key?(responses, "unknown")
    end

    test "acknowledges without calling update_task/3 when nothing is outstanding" do
      params = %{"taskId" => "working", "inputResponses" => %{"name" => %{"action" => "accept"}}}

      assert {:reply, %{}, _} = dispatch(session(), "tasks/update", params)
      refute_received {:update_task, _, _}
    end

    test "passes through an error from update_task/3" do
      params = %{
        "taskId" => "rejecting",
        "inputResponses" => %{"name" => %{"action" => "accept"}}
      }

      assert {:error, %{code: -32602, data: %{inputResponses: "rejected"}}, _} =
               dispatch(session(), "tasks/update", params)
    end

    test "requires inputResponses to be an object" do
      assert {:error, %{code: -32602}, _} =
               dispatch(session(), "tasks/update", %{"taskId" => "input", "inputResponses" => []})
    end

    test "is not found for a task the caller cannot see" do
      params = %{"taskId" => "nope", "inputResponses" => %{"name" => %{"action" => "accept"}}}
      assert {:error, @not_found, _} = dispatch(session(), "tasks/update", params)
    end

    test "acknowledges when the router does not implement update_task/3" do
      params = %{"taskId" => "input", "inputResponses" => %{"name" => %{"action" => "accept"}}}

      assert {:reply, %{}, _} = dispatch(session(GetOnlyRouter), "tasks/update", params)
    end

    test "raises a clear error when update_task/3 returns an unexpected value" do
      params = %{"taskId" => "input", "inputResponses" => %{"name" => %{"action" => "accept"}}}

      assert_raise ArgumentError, ~r/update_task\/3/, fn ->
        dispatch(session(BadRouter), "tasks/update", params)
      end
    end
  end

  describe "tasks/cancel" do
    test "calls cancel_task/2 and acknowledges" do
      assert {:reply, %{}, _} = dispatch(session(), "tasks/cancel", %{"taskId" => "working"})
      assert_received {:cancel_task, "working"}
    end

    test "acknowledges when the router does not implement cancel_task/2" do
      assert {:reply, %{}, _} =
               dispatch(session(GetOnlyRouter), "tasks/cancel", %{"taskId" => "working"})
    end

    test "is not found for a task the caller cannot see" do
      assert {:error, @not_found, _} = dispatch(session(), "tasks/cancel", %{"taskId" => "nope"})
      refute_received {:cancel_task, _}
    end
  end

  describe "Phantom.Test task helpers" do
    test "call_tool/4 declares the extension with tasks: true" do
      session(Router, client_capabilities: %{})
      |> call_tool(:always_task, %{}, tasks: true)
      |> assert_task(id: "task-1", status: :working)
    end

    test "tasks: true requires a stateless session" do
      assert_raise ArgumentError, ~r/protocol_version/, fn ->
        call_tool(build_session(Router), :always_task, %{}, tasks: true)
      end
    end

    test "get_task/3 returns the task" do
      session(Router, client_capabilities: %{})
      |> get_task("input")
      |> assert_task(status: :input_required)
    end

    test "get_task/3 returns a JSON-RPC error for an unknown task" do
      session()
      |> get_task("nope")
      |> assert_jsonrpc_error(code: -32602, message: "Failed to retrieve task: Task not found")
    end

    test "update_task/4 sends input responses" do
      assert update_task(session(), "input", %{name: %{"action" => "accept"}}) == %{}
      assert_received {:update_task, "input", %{"name" => %{"action" => "accept"}}}
    end

    test "cancel_task/3 cancels" do
      assert cancel_task(session(), "working") == %{}
      assert_received {:cancel_task, "working"}
    end

    test "assert_task/2 fails on a mismatch" do
      task = get_task(session(), "working")

      assert_raise ExUnit.AssertionError, ~r/status/, fn ->
        assert_task(task, status: :completed)
      end

      assert_raise ExUnit.AssertionError, ~r/expected a task/, fn ->
        assert_task(%{content: []})
      end
    end
  end
end

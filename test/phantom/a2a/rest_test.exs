defmodule Phantom.A2A.RESTTest.Agent do
  use Phantom.A2A.Agent,
    name: "REST",
    description: "Served over HTTP+JSON",
    push_notifications: true,
    extended_card: true

  alias Phantom.A2A.{Artifact, Message, Part, Task, TaskStatus}

  @table Phantom.A2A.RESTTest

  def handle_message(%Message{parts: [%Part{text: "tenant"}]}, ctx),
    do: {:reply, Message.agent("tenant=#{ctx.tenant}"), ctx}

  def handle_message(%Message{parts: [%Part{text: "work"}]}, ctx) do
    ref = ctx.task_ref

    spawn(fn ->
      Phantom.A2A.publish(ref, Task.status(:working, "Working"))
      Phantom.A2A.publish(ref, Artifact.update("out", [Part.text("done")]))
      Phantom.A2A.publish(ref, Task.status(:completed))
    end)

    {:reply, Task.submitted(ctx), ctx}
  end

  def handle_message(_message, ctx), do: {:reply, Message.agent("pong"), ctx}

  def resolve(_params, _session), do: {:error, :not_found}

  def get_task("missing", _ctx), do: {:error, :not_found}

  def get_task("live", %{task_ref: ref}) do
    spawn(fn -> Phantom.A2A.publish(ref, Task.status(:completed)) end)
    {:ok, task("live", :working)}
  end

  def get_task(id, _ctx), do: {:ok, task(id, :working)}

  def cancel_task(task, _ctx), do: {:ok, %{task | status: %TaskStatus{state: :canceled}}}

  def list_tasks(filter, _ctx) do
    tasks = for id <- ["a", "b"], do: task(id, :completed)
    send(Phantom.A2A.RESTTest, {:filter, filter})
    {:ok, %{tasks: Enum.take(tasks, filter.page_size), next_page_token: nil}}
  end

  def create_push_config(config, _ctx) do
    :ets.insert(@table, {config.task_id, config})
    {:ok, config}
  end

  def get_push_config(task_id, id, _ctx) do
    case for({^task_id, %{id: ^id} = c} <- :ets.lookup(@table, task_id), do: c) do
      [config] -> {:ok, config}
      [] -> {:error, :not_found}
    end
  end

  def list_push_configs(task_id, _ctx),
    do: {:ok, for({_, config} <- :ets.lookup(@table, task_id), do: config)}

  def delete_push_config(task_id, id, _ctx) do
    :ets.match_delete(@table, {task_id, %{id: id}})
    :ok
  end

  defp task(id, state) do
    %Task{
      id: id,
      context_id: "ctx-1",
      status: %TaskStatus{state: state},
      artifacts: [Artifact.new("out", [Part.text(id)])],
      history: [Message.user("one"), Message.user("two")]
    }
  end
end

defmodule Phantom.A2A.RESTTest.Router do
  use Phantom.Router, name: "REST", vsn: "1.0"

  agent "rest", Phantom.A2A.RESTTest.Agent
  agent ":org/:agent_key", Phantom.A2A.RESTTest.Agent, :resolve

  def connect(session, conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer nope"] -> {:unauthorized, %{method: "Bearer"}}
      ["Bearer bare"] -> {:unauthorized, nil}
      ["Bearer broken"] -> {:error, {:db, "postgres://admin:secret@db"}}
      _ -> {:ok, session}
    end
  end
end

defmodule Phantom.A2A.RESTTest do
  use ExUnit.Case, async: false

  alias Phantom.A2A.RESTTest.Router

  setup_all do
    start_supervised!({Agent, fn -> :ets.new(__MODULE__, [:named_table, :public, :bag]) end})
    start_supervised!({Phoenix.PubSub, name: Phantom.A2A.RESTTest.PubSub})
    :ok
  end

  setup do
    :ets.delete_all_objects(__MODULE__)
    Process.register(self(), __MODULE__)
    :ok
  end

  defp request(method, path, body \\ nil, opts \\ []) do
    headers = Keyword.get(opts, :headers, [{"a2a-version", "1.0"}])

    plug_opts =
      Phantom.A2A.Plug.init(
        [router: Router, pubsub: Phantom.A2A.RESTTest.PubSub] ++ Keyword.get(opts, :plug, [])
      )

    method
    |> Plug.Test.conn(path, body && JSON.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(
      &Enum.reduce(headers, &1, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    )
    |> Phantom.A2A.Plug.call(plug_opts)
  end

  defp json(conn), do: {conn.status, JSON.decode!(conn.resp_body)}

  defp events(conn) do
    for event <- String.split(conn.resp_body, "\n\n", trim: true),
        not String.starts_with?(event, ":") do
      ["id: " <> _, "data: " <> data] = String.split(event, "\n")
      JSON.decode!(data)
    end
  end

  defp message(text),
    do: %{
      "message" => %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => text}]}
    }

  test "the card lists both bindings at the agent's URL" do
    {200, card} = json(request(:get, "/rest/agent-card.json"))

    assert [
             %{"protocolBinding" => "JSONRPC", "url" => url},
             %{"protocolBinding" => "HTTP+JSON", "url" => url}
           ] = card["supportedInterfaces"]

    assert url == "http://www.example.com/rest"
  end

  test "message:send answers with the bare result" do
    assert {200, %{"message" => %{"parts" => [%{"text" => "pong"}]}}} =
             json(request(:post, "/rest/message:send", message("ping")))
  end

  test "a segment before the route is the tenant" do
    assert {200, %{"message" => %{"parts" => [%{"text" => "tenant=acme"}]}}} =
             json(request(:post, "/rest/acme/message:send", message("tenant")))
  end

  test "a static agent and a tenant match before a dynamic agent" do
    assert {200, %{"message" => %{"parts" => [%{"text" => "tenant=acme"}]}}} =
             json(request(:post, "/rest/acme/message:send", message("tenant")))

    assert {404, _} = json(request(:post, "/other/acme/message:send", message("tenant")))
  end

  test "connect/2 can refuse without www-authenticate info" do
    headers = [{"a2a-version", "1.0"}, {"authorization", "Bearer bare"}]
    conn = request(:post, "/rest/message:send", message("ping"), headers: headers)

    assert conn.status == 401
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []
  end

  test "connect/2 errors don't reach the client" do
    headers = [{"a2a-version", "1.0"}, {"authorization", "Bearer broken"}]

    assert {400, body} =
             json(request(:post, "/rest/message:send", message("ping"), headers: headers))

    refute JSON.encode!(body) =~ "secret"
  end

  test "message:stream streams bare events" do
    conn = request(:post, "/rest/message:stream", message("work"))
    assert ["text/event-stream" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

    assert [
             %{"task" => %{"status" => %{"state" => "TASK_STATE_SUBMITTED"}}},
             %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_WORKING"}}},
             %{"artifactUpdate" => %{"artifact" => %{"artifactId" => "out"}}},
             %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}
           ] = events(conn)
  end

  test "tasks: get, list, cancel, and subscribe" do
    assert {200, %{"id" => "t1", "history" => [%{}]}} =
             json(request(:get, "/rest/tasks/t1?historyLength=1"))

    assert {200,
            %{
              "tasks" => [%{"id" => "a", "artifacts" => [_]}],
              "nextPageToken" => "",
              "pageSize" => 1
            }} =
             json(
               request(
                 :get,
                 "/rest/tasks?contextId=ctx-1&pageSize=1&includeArtifacts=true&status=TASK_STATE_COMPLETED"
               )
             )

    assert_received {:filter, %{context_id: "ctx-1", page_size: 1, status: :completed}}

    assert {200, %{"id" => "t1", "status" => %{"state" => "TASK_STATE_CANCELED"}}} =
             json(request(:post, "/rest/tasks/t1:cancel", %{}))

    assert [%{"task" => %{"id" => "live"}}, %{"statusUpdate" => %{"taskId" => "live"}}] =
             events(request(:get, "/rest/tasks/live:subscribe"))
  end

  test "responses are application/a2a+json" do
    conn = request(:post, "/rest/message:send", message("ping"))
    assert ["application/a2a+json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

    conn = request(:get, "/rest/tasks/missing")
    assert ["application/a2a+json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
  end

  test "cancel takes no body, and subscribe takes POST too" do
    conn =
      :post
      |> Plug.Test.conn("/rest/tasks/t1:cancel", "")
      |> Plug.Conn.put_req_header("a2a-version", "1.0")
      |> Phantom.A2A.Plug.call(Phantom.A2A.Plug.init(router: Router))

    assert {200, %{"status" => %{"state" => "TASK_STATE_CANCELED"}}} = json(conn)

    assert [%{"task" => %{"id" => "live"}}, %{"statusUpdate" => _}] =
             events(request(:post, "/rest/tasks/live:subscribe", %{}))
  end

  test "push notification configs" do
    assert {200, %{"id" => id, "taskId" => "t1"}} =
             json(
               request(:post, "/rest/tasks/t1/pushNotificationConfigs", %{
                 "url" => "https://example.com/hook"
               })
             )

    assert {200, %{"id" => ^id}} =
             json(request(:get, "/rest/tasks/t1/pushNotificationConfigs/#{id}"))

    assert {200, %{"configs" => [%{"id" => ^id}]}} =
             json(request(:get, "/rest/tasks/t1/pushNotificationConfigs"))

    assert %{status: 200} = request(:delete, "/rest/tasks/t1/pushNotificationConfigs/#{id}")
    assert {404, _} = json(request(:get, "/rest/tasks/t1/pushNotificationConfigs/#{id}"))
  end

  test "extendedAgentCard" do
    assert {200, %{"name" => "REST", "capabilities" => %{"extendedAgentCard" => true}}} =
             json(request(:get, "/rest/extendedAgentCard"))
  end

  test "errors are google.rpc.Status with HTTP status codes" do
    assert {404,
            %{
              "error" => %{
                "code" => 404,
                "status" => "NOT_FOUND",
                "message" => "Task not found: missing",
                "details" => [%{"reason" => "TASK_NOT_FOUND", "domain" => "a2a-protocol.org"}]
              }
            }} = json(request(:get, "/rest/tasks/missing"))

    assert {400, %{"error" => %{"status" => "INVALID_ARGUMENT"}}} =
             json(request(:post, "/rest/message:send", %{"message" => %{}}))

    assert {400,
            %{
              "error" => %{
                "status" => "FAILED_PRECONDITION",
                "details" => [%{"reason" => "VERSION_NOT_SUPPORTED"}]
              }
            }} =
             json(request(:get, "/rest/tasks/t1", nil, headers: []))

    conn =
      request(:get, "/rest/tasks/t1", nil,
        headers: [{"a2a-version", "1.0"}, {"authorization", "Bearer nope"}]
      )

    assert {401, %{"error" => %{"status" => "UNAUTHENTICATED"}}} = json(conn)
    assert [_] = Plug.Conn.get_resp_header(conn, "www-authenticate")
  end

  test "invalid JSON is INVALID_ARGUMENT" do
    conn =
      :post
      |> Plug.Test.conn("/rest/message:send", "{nope")
      |> Plug.Conn.put_req_header("a2a-version", "1.0")
      |> Phantom.A2A.Plug.call(Phantom.A2A.Plug.init(router: Router))

    assert {400, %{"error" => %{"status" => "INVALID_ARGUMENT"}}} = json(conn)
  end

  test "bindings: [:jsonrpc] turns HTTP+JSON off" do
    {200, card} = json(request(:get, "/rest/agent-card.json", nil, plug: [bindings: [:jsonrpc]]))
    assert [%{"protocolBinding" => "JSONRPC"}] = card["supportedInterfaces"]

    assert %{status: 404} = request(:get, "/rest/tasks/t1", nil, plug: [bindings: [:jsonrpc]])
  end

  test "agent paths can't use the binding's segments" do
    for path <- ["tasks", "a/extendedAgentCard", "pushNotificationConfigs/b"] do
      assert_raise ArgumentError, ~r/reserved/, fn ->
        Phantom.Router.agent_route(path, __MODULE__, [])
      end
    end
  end
end

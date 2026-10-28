defmodule Phantom.A2A.PlugTest.Research do
  use Phantom.A2A.Agent,
    name: "Research",
    description: "Designs and reviews research studies",
    input_modes: ~w[text/plain application/json],
    output_modes: ~w[text/markdown]

  alias Phantom.A2A.{Artifact, Message, Part, Task, TaskStatus}

  @description "Review a study and suggest missing questions"
  skill :study_review, tags: ~w[research], examples: ["Review study 42"]

  skill :quick_answer, name: "Quick answer", description: "Answer a short question", tags: []

  def handle_message(%Message{task_id: nil, parts: [%Part{text: "ping"}]}, ctx),
    do: {:reply, Message.agent("pong"), ctx}

  def handle_message(%Message{parts: [%Part{text: "agent"}]}, ctx),
    do: {:reply, Message.agent("#{ctx.agent.id} #{inspect(ctx.agent.opts)}"), ctx}

  def handle_message(%Message{parts: [%Part{text: "tenant"}]}, ctx),
    do: {:reply, Message.agent("#{ctx.assigns.tenant}/#{ctx.tenant}"), ctx}

  def handle_message(%Message{parts: [%Part{text: "done"}]}, ctx),
    do: {:reply, Task.submitted(ctx, status: %TaskStatus{state: :completed}), ctx}

  def handle_message(%Message{parts: [%Part{text: "explode"}]}, _ctx), do: raise("boom")
  def handle_message(%Message{parts: [%Part{text: "invalid"}]}, _ctx), do: :nope

  def handle_message(%Message{parts: [%Part{text: "refuse"}]}, ctx),
    do: {:error, Phantom.A2A.Error.unsupported_operation("Not today"), ctx}

  def handle_message(%Message{parts: [%Part{text: "work"}]}, ctx) do
    ref = ctx.task_ref

    spawn(fn ->
      Phantom.A2A.publish(ref, Task.status(:working, "Reading study…"))
      Phantom.A2A.publish(ref, Artifact.update("review", [Part.text("## Gaps")]))
      Phantom.A2A.publish(ref, Artifact.update("review", [Part.text("- Ages")], append: true))
      Phantom.A2A.publish(ref, Task.status(:input_required, "Include demographics?"))
    end)

    {:reply, Task.submitted(ctx), ctx}
  end

  def handle_message(%Message{task_id: task_id} = message, ctx) when is_binary(task_id) do
    send(ctx.assigns.test, {:continued, ctx.task_ref.task_id, ctx.context_id})
    {:ok, task} = get_task(task_id, ctx)

    {:reply, %{task | status: %TaskStatus{state: :completed}, history: task.history ++ [message]},
     ctx}
  end

  def get_task("missing", _ctx), do: {:error, :not_found}

  def get_task("slow", %{task_ref: %Phantom.A2A.TaskRef{} = ref}) do
    spawn(fn ->
      Process.sleep(60)
      Phantom.A2A.publish(ref, Task.status(:completed))
    end)

    {:ok, %Task{id: "slow", context_id: "ctx-1", status: %TaskStatus{state: :working}}}
  end

  # Event 2 is already in the snapshot when it is published, as when it is
  # saved between the subscriber listening and fetching the task.
  def get_task("raced", %{task_ref: %Phantom.A2A.TaskRef{} = ref}) do
    spawn(fn ->
      Phantom.A2A.publish(ref, %{Artifact.update("out", [Part.text("a")]) | sequence: 2})
      Phantom.A2A.publish(ref, %{Task.status(:completed) | sequence: 3})
    end)

    {:ok,
     %Task{
       id: "raced",
       context_id: "ctx-1",
       status: %TaskStatus{state: :working},
       artifacts: [Artifact.new("out", [Part.text("a")])],
       sequence: 2
     }}
  end

  # A subscriber is listening by the time Phantom fetches the task.
  def get_task("live", %{task_ref: %Phantom.A2A.TaskRef{} = ref}) do
    spawn(fn ->
      Phantom.A2A.publish(ref, Artifact.update("out", [Part.text("streamed")]))
      Phantom.A2A.publish(ref, Task.status(:completed))
    end)

    {:ok, %Task{id: "live", context_id: "ctx-1", status: %TaskStatus{state: :working}}}
  end

  def get_task(id, _ctx) do
    state =
      case id do
        "finished" -> :completed
        "was-canceled" -> :canceled
        "stuck" -> :working
        _ -> :input_required
      end

    history =
      for i <- 1..3, do: %Message{message_id: "m#{i}", role: :user, parts: [Part.text("#{i}")]}

    {:ok, %Task{id: id, context_id: "ctx-1", status: %TaskStatus{state: state}, history: history}}
  end

  def cancel_task(%Task{id: "stuck"}, _ctx), do: {:error, :not_cancelable}
  def cancel_task(task, _ctx), do: {:ok, %{task | status: %TaskStatus{state: :canceled}}}

  def list_tasks(filter, ctx) do
    send(ctx.assigns.test, {:list_filter, filter})

    tasks =
      for id <- ["a", "b"] do
        %Task{
          id: id,
          context_id: "ctx-1",
          status: %TaskStatus{state: :completed},
          artifacts: [Artifact.new("out", [Part.text(id)])],
          history: [Message.user("one"), Message.user("two")]
        }
      end

    {:ok,
     %{
       tasks: tasks,
       next_page_token: if(filter.page_token, do: nil, else: "page-2"),
       total_size: 3
     }}
  end
end

defmodule Phantom.A2A.PlugTest.Minimal do
  use Phantom.A2A.Agent, name: "Minimal", description: "Does little"

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Message.agent("ok"), ctx}
end

defmodule Phantom.A2A.PlugTest.Router do
  use Phantom.Router,
    name: "A2A test",
    vsn: "2.0",
    a2a: [
      well_known: "research",
      provider: %{"organization" => "Phantom", "url" => "https://phantom.example"},
      security_schemes: %{"bearer" => %{"httpAuthSecurityScheme" => %{"scheme" => "Bearer"}}},
      security_requirements: [%{"schemes" => %{"bearer" => %{"list" => []}}}]
    ]

  agent "research", Phantom.A2A.PlugTest.Research
  agent "research-es", Phantom.A2A.PlugTest.Research, locale: "es"
  agent "teams/minimal", Phantom.A2A.PlugTest.Minimal

  def connect(_session, %Plug.Conn{body_params: %{"params" => %{"tenant" => "other-org"}}}),
    do: {:forbidden, "Not a member of other-org"}

  def connect(session, %Plug.Conn{} = conn) do
    session = Phantom.Session.assign(session, tenant: tenant(conn))

    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer limited"] ->
        {:ok, session |> Phantom.Session.assign(test: test_pid(conn)) |> allow(["research"])}

      ["Bearer " <> _] ->
        {:ok, Phantom.Session.assign(session, test: test_pid(conn))}

      _ ->
        {:unauthorized, %{method: "Bearer", resource_metadata: "https://example.com/meta"}}
    end
  end

  defp tenant(%Plug.Conn{body_params: %{"params" => %{"tenant" => tenant}}}), do: tenant
  defp tenant(_conn), do: nil

  defp allow(session, agents), do: Phantom.Session.allow_agents(session, agents)

  defp test_pid(conn) do
    case Plug.Conn.get_req_header(conn, "x-test-pid") do
      [pid] -> pid |> Base.decode64!() |> :erlang.binary_to_term()
      [] -> nil
    end
  end
end

defmodule Phantom.A2A.PlugTest.ConfiguredRouter do
  use Phantom.Router, name: "Configured"

  agent "research", Phantom.A2A.PlugTest.Research
end

defmodule Phantom.A2A.PlugTest.HTTP do
  use Plug.Router

  plug :match

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON

  plug :dispatch

  get("/.well-known/agent-card.json",
    to: Phantom.A2A.Plug,
    init_opts: [router: Phantom.A2A.PlugTest.Router, mount: "/a2a"]
  )

  forward "/a2a",
    to: Phantom.A2A.Plug,
    init_opts: [router: Phantom.A2A.PlugTest.Router, validate_origin: false]

  forward "/configured/a2a",
    to: Phantom.A2A.Plug,
    init_opts: [router: Phantom.A2A.PlugTest.ConfiguredRouter]

  forward "/keepalive/a2a",
    to: Phantom.A2A.Plug,
    init_opts: [
      router: Phantom.A2A.PlugTest.Router,
      pubsub: Phantom.A2A.PlugTest.PubSub,
      keepalive: 10
    ]

  forward "/pubsub/a2a",
    to: Phantom.A2A.Plug,
    init_opts: [
      router: Phantom.A2A.PlugTest.Router,
      pubsub: Phantom.A2A.PlugTest.PubSub,
      blocking_timeout: 1_000
    ]
end

defmodule Phantom.A2A.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Phantom.A2A.PlugTest.HTTP

  setup_all do
    start_supervised!({Phoenix.PubSub, name: Phantom.A2A.PlugTest.PubSub})
    :ok
  end

  defp get_json(path) do
    conn = :get |> conn(path) |> HTTP.call(HTTP.init([]))
    {conn.status, JSON.decode!(conn.resp_body)}
  end

  defp rpc(path, method, params, opts \\ []) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    conn =
      :post
      |> conn(path, JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-test-pid", self() |> :erlang.term_to_binary() |> Base.encode64())

    conn =
      Enum.reduce(
        Keyword.get(opts, :headers, [
          {"a2a-version", "1.0"},
          {"authorization", "Bearer token"}
        ]),
        conn,
        fn {k, v}, conn -> put_req_header(conn, k, v) end
      )

    conn = HTTP.call(conn, HTTP.init([]))
    {conn, JSON.decode!(conn.resp_body)}
  end

  # Sends a request answered with SSE, and returns its events' ids and data.
  defp stream(path, method, params) do
    body = %{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params}

    conn =
      :post
      |> conn(path, JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("a2a-version", "1.0")
      |> put_req_header("authorization", "Bearer token")
      |> put_req_header("x-test-pid", self() |> :erlang.term_to_binary() |> Base.encode64())
      |> HTTP.call(HTTP.init([]))

    events =
      for event <- String.split(conn.resp_body, "\n\n", trim: true),
          not String.starts_with?(event, ":") do
        fields =
          for line <- String.split(event, "\n"), into: %{} do
            [key, value] = String.split(line, ": ", parts: 2)
            {key, value}
          end

        {fields["id"], JSON.decode!(fields["data"])}
      end

    {conn, events}
  end

  defp send_message(path, text, extra \\ %{}) do
    message =
      Map.merge(
        %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => text}]},
        extra
      )

    {_conn, body} = rpc(path, "SendMessage", %{"message" => message})
    body
  end

  describe "agent card" do
    test "serves each agent's card under the mount" do
      assert {200, card} = get_json("/a2a/research/agent-card.json")

      assert %{
               "name" => "Research",
               "description" => "Designs and reviews research studies",
               "version" => "2.0",
               "defaultInputModes" => ["text/plain", "application/json"],
               "defaultOutputModes" => ["text/markdown"],
               "provider" => %{"organization" => "Phantom"},
               "securitySchemes" => %{"bearer" => _},
               "securityRequirements" => [_],
               "capabilities" =>
                 %{
                   "streaming" => false,
                   "pushNotifications" => false,
                   "extendedAgentCard" => false
                 } = capabilities,
               "supportedInterfaces" => [
                 %{
                   "url" => "http://www.example.com/a2a/research",
                   "protocolBinding" => "JSONRPC",
                   "protocolVersion" => "1.0"
                 },
                 %{
                   "url" => "http://www.example.com/a2a/research",
                   "protocolBinding" => "HTTP+JSON",
                   "protocolVersion" => "1.0"
                 }
               ],
               "skills" => [
                 %{
                   "id" => "study_review",
                   "name" => "Study review",
                   "description" => "Review a study and suggest missing questions",
                   "tags" => ["research"],
                   "examples" => ["Review study 42"]
                 },
                 %{"id" => "quick_answer", "name" => "Quick answer", "tags" => []}
               ]
             } = card

      refute Map.has_key?(capabilities, "extensions")
    end

    test "serves nested agent paths" do
      assert {200,
              %{"name" => "Minimal", "skills" => [], "supportedInterfaces" => [interface | _]}} =
               get_json("/a2a/teams/minimal/agent-card.json")

      assert interface["url"] == "http://www.example.com/a2a/teams/minimal"
    end

    test "serves the well-known agent with the mount's URL" do
      assert {200, %{"name" => "Research", "supportedInterfaces" => [%{"url" => url} | _]}} =
               get_json("/.well-known/agent-card.json")

      assert url == "http://www.example.com/a2a/research"
    end

    test "advertises streaming only with a pubsub" do
      assert {200, %{"capabilities" => %{"streaming" => true}}} =
               get_json("/pubsub/a2a/research/agent-card.json")

      assert {200, %{"capabilities" => %{"streaming" => false}}} =
               get_json("/a2a/research/agent-card.json")
    end

    test "takes options from the router's config" do
      Application.put_env(
        Phantom.A2A.PlugTest.ConfiguredRouter,
        :pubsub,
        Phantom.A2A.PlugTest.PubSub
      )

      on_exit(fn -> Application.delete_env(Phantom.A2A.PlugTest.ConfiguredRouter, :pubsub) end)

      assert {200, %{"capabilities" => %{"streaming" => true}}} =
               get_json("/configured/a2a/research/agent-card.json")
    end

    test "can be cached" do
      conn = :get |> conn("/a2a/research/agent-card.json") |> HTTP.call(HTTP.init([]))
      assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
      assert [etag] = get_resp_header(conn, "etag")

      conn =
        :get
        |> conn("/a2a/research/agent-card.json")
        |> put_req_header("if-none-match", etag)
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 304
      assert conn.resp_body == ""
    end

    test "unknown agents are not found" do
      assert {404, _} = get_json("/a2a/nope/agent-card.json")
    end
  end

  describe "JSON-RPC" do
    test "requires A2A-Version 1.x" do
      {conn, body} =
        rpc("/a2a/research", "GetTask", %{"id" => "t1"},
          headers: [{"authorization", "Bearer token"}]
        )

      assert conn.status == 200

      assert %{
               "id" => 1,
               "error" => %{
                 "code" => -32009,
                 "data" => [%{"@type" => "type.googleapis.com/google.rpc.ErrorInfo"} = info]
               }
             } = body

      assert %{"reason" => "VERSION_NOT_SUPPORTED", "domain" => "a2a-protocol.org"} = info

      {_conn, body} =
        rpc("/a2a/research", "GetTask", %{"id" => "t1"},
          headers: [{"authorization", "Bearer token"}, {"a2a-version", "0.3"}]
        )

      assert %{"error" => %{"code" => -32009}} = body

      {_conn, body} =
        rpc("/a2a/research", "GetTask", %{"id" => "t1"},
          headers: [{"authorization", "Bearer token"}, {"a2a-version", "1.2"}]
        )

      assert %{"result" => %{"id" => "t1"}} = body
    end

    test "unknown methods and agents" do
      assert {_, %{"error" => %{"code" => -32601}}} = rpc("/a2a/research", "message/send", %{})
      assert {conn, _} = rpc("/a2a/nope", "GetTask", %{"id" => "t1"})
      assert conn.status == 404
    end

    test "rejects a JSON-RPC envelope that isn't a request" do
      conn =
        :post
        |> conn("/a2a/research", JSON.encode!([%{"jsonrpc" => "2.0"}]))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("a2a-version", "1.0")
        |> HTTP.call(HTTP.init([]))

      assert %{"error" => %{"code" => -32600}} = JSON.decode!(conn.resp_body)
    end

    test "connect/2 can reject the request" do
      {conn, body} =
        rpc("/a2a/research", "GetTask", %{"id" => "t1"}, headers: [{"a2a-version", "1.0"}])

      assert conn.status == 401
      assert [www_authenticate] = get_resp_header(conn, "www-authenticate")
      assert www_authenticate =~ "Bearer"
      assert %{"error" => _} = body
    end

    test "allow_agents/2 hides other agents" do
      headers = [{"a2a-version", "1.0"}, {"authorization", "Bearer limited"}]

      assert {%{status: 200}, _} =
               rpc("/a2a/research", "GetTask", %{"id" => "t1"}, headers: headers)

      assert {%{status: 404}, _} =
               rpc("/a2a/teams/minimal", "GetTask", %{"id" => "t1"}, headers: headers)
    end
  end

  describe "SendMessage" do
    test "connect/2 sees the tenant of a parsed body" do
      assert %{"result" => %{"message" => %{"parts" => [%{"text" => "acme/acme"}]}}} =
               rpc("/a2a/research", "SendMessage", %{
                 "tenant" => "acme",
                 "message" => %{
                   "messageId" => "m1",
                   "role" => "ROLE_USER",
                   "parts" => [%{"text" => "tenant"}]
                 }
               })
               |> elem(1)

      assert {%{status: 403}, _} =
               rpc("/a2a/research", "GetTask", %{"id" => "t1", "tenant" => "other-org"})
    end

    test "answers with a message in a new context" do
      assert %{
               "result" => %{
                 "message" => %{"role" => "ROLE_AGENT", "parts" => [%{"text" => "pong"}]} = msg
               }
             } = send_message("/a2a/research", "ping")

      assert is_binary(msg["contextId"])
      refute Map.has_key?(msg, "taskId")
    end

    test "keeps the client's context and passes the route's options" do
      assert %{
               "result" => %{
                 "message" => %{"contextId" => "ctx-9", "parts" => [%{"text" => text}]}
               }
             } =
               send_message("/a2a/research-es", "agent", %{"contextId" => "ctx-9"})

      assert text == ~s(research-es [locale: "es"])
    end

    test "answers with a finished task" do
      assert %{
               "result" => %{
                 "task" => %{
                   "id" => id,
                   "status" => %{"state" => "TASK_STATE_COMPLETED"},
                   "history" => [%{"messageId" => "m1"}]
                 }
               }
             } = send_message("/a2a/research", "done")

      assert is_binary(id)
    end

    test "without a pubsub, returns the task as the agent returned it" do
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_SUBMITTED"}}}} =
               send_message("/a2a/research", "work")
    end

    test "with a pubsub, waits until the task needs input" do
      assert %{
               "result" => %{
                 "task" => %{
                   "status" => %{
                     "state" => "TASK_STATE_INPUT_REQUIRED",
                     "message" => %{"parts" => [%{"text" => "Include demographics?"}]}
                   },
                   "artifacts" => [
                     %{
                       "artifactId" => "review",
                       "parts" => [%{"text" => "## Gaps"}, %{"text" => "- Ages"}]
                     }
                   ]
                 }
               }
             } = send_message("/pubsub/a2a/research", "work")
    end

    test "returnImmediately answers with the submitted task" do
      message = %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => "work"}]}

      {_conn, body} =
        rpc("/pubsub/a2a/research", "SendMessage", %{
          "message" => message,
          "configuration" => %{"returnImmediately" => true}
        })

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_SUBMITTED"}}}} =
               body
    end

    test "continues an existing task" do
      assert %{
               "result" => %{
                 "task" => %{"id" => "t-7", "status" => %{"state" => "TASK_STATE_COMPLETED"}}
               }
             } =
               send_message("/a2a/research", "yes", %{"taskId" => "t-7"})

      assert_received {:continued, "t-7", "ctx-1"}
    end

    test "rejects continuing a task that is missing, finished, or in another context" do
      assert %{"error" => %{"code" => -32001}} =
               send_message("/a2a/research", "yes", %{"taskId" => "missing"})

      assert %{"error" => %{"code" => -32004}} =
               send_message("/a2a/research", "yes", %{"taskId" => "finished"})

      assert %{"error" => %{"code" => -32602}} =
               send_message("/a2a/research", "yes", %{"taskId" => "t-7", "contextId" => "other"})

      assert %{"error" => %{"code" => -32001}} =
               send_message("/a2a/teams/minimal", "yes", %{"taskId" => "t-7"})
    end

    test "rejects invalid messages and unsupported media types" do
      {_conn, body} =
        rpc("/a2a/research", "SendMessage", %{"message" => %{"role" => "ROLE_USER"}})

      assert %{"error" => %{"code" => -32602}} = body

      assert %{"error" => %{"code" => -32005}} =
               send_message("/a2a/research", "ping", %{
                 "parts" => [%{"raw" => "AA==", "mediaType" => "image/png"}]
               })
    end

    test "handler errors" do
      assert %{"error" => %{"code" => -32004, "message" => "Not today"}} =
               send_message("/a2a/research", "refuse")

      assert %{"error" => %{"code" => -32006}} = send_message("/a2a/research", "invalid")
    end

    test "a raise answers with an internal error, then reraises" do
      assert_raise Plug.Conn.WrapperError, ~r/boom/, fn ->
        send_message("/a2a/research", "explode")
      end

      assert_received {_ref, {200, _headers, body}}
      assert %{"error" => %{"code" => -32603, "message" => "Internal error"}} = JSON.decode!(body)
    end

    test "streaming needs a pubsub" do
      message = %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => "ping"}]}

      assert {_, %{"error" => %{"code" => -32004}}} =
               rpc("/a2a/research", "SendStreamingMessage", %{"message" => message})
    end
  end

  describe "unparsed bodies" do
    defp raw(body) do
      :post
      |> conn("/research", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("a2a-version", "1.0")
      |> put_req_header("authorization", "Bearer token")
      |> Phantom.A2A.Plug.call(Phantom.A2A.Plug.init(router: Phantom.A2A.PlugTest.Router))
    end

    test "are read and decoded" do
      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "GetTask",
          "params" => %{"id" => "t1"}
        })

      assert %{"result" => %{"id" => "t1"}} = JSON.decode!(raw(body).resp_body)
    end

    test "connect/2 sees the body, such as the tenant" do
      message = %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => "tenant"}]}

      body = fn tenant ->
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "SendMessage",
          "params" => %{"tenant" => tenant, "message" => message}
        })
      end

      assert %{"result" => %{"message" => %{"parts" => [%{"text" => "acme/acme"}]}}} =
               JSON.decode!(raw(body.("acme")).resp_body)

      conn = raw(body.("other-org"))
      assert conn.status == 403

      assert %{"error" => %{"message" => "Not a member of other-org"}} =
               JSON.decode!(conn.resp_body)
    end

    test "invalid JSON is a JSON-RPC parse error" do
      conn = raw("{this is not valid json")
      assert conn.status == 200
      assert %{"id" => nil, "error" => %{"code" => -32700}} = JSON.decode!(conn.resp_body)
    end
  end

  describe "GetExtendedAgentCard" do
    test "is unsupported when the card doesn't advertise it" do
      assert {_, %{"error" => %{"code" => -32004}}} =
               rpc("/a2a/research", "GetExtendedAgentCard", %{})
    end
  end

  describe "GetTask" do
    test "returns the task with trimmed history" do
      {_conn, body} = rpc("/a2a/research", "GetTask", %{"id" => "t-7", "historyLength" => 1})

      assert %{"result" => %{"id" => "t-7", "history" => [%{"messageId" => "m3"}]}} = body
    end

    test "missing tasks, and agents without get_task/2" do
      assert {_, %{"error" => %{"code" => -32001}}} =
               rpc("/a2a/research", "GetTask", %{"id" => "missing"})

      assert {_, %{"error" => %{"code" => -32001}}} =
               rpc("/a2a/teams/minimal", "GetTask", %{"id" => "t-7"})

      assert {_, %{"error" => %{"code" => -32602}}} = rpc("/a2a/research", "GetTask", %{})
    end
  end

  describe "CancelTask" do
    test "cancels through the agent" do
      assert {_, %{"result" => %{"id" => "t-7", "status" => %{"state" => "TASK_STATE_CANCELED"}}}} =
               rpc("/a2a/research", "CancelTask", %{"id" => "t-7"})

      assert {_, %{"error" => %{"code" => -32002}}} =
               rpc("/a2a/research", "CancelTask", %{"id" => "stuck"})

      assert {_, %{"error" => %{"code" => -32001}}} =
               rpc("/a2a/research", "CancelTask", %{"id" => "missing"})

      assert {_, %{"error" => %{"code" => -32001}}} =
               rpc("/a2a/teams/minimal", "CancelTask", %{"id" => "t-7"})
    end

    test "a finished task can't be canceled, and a canceled one is returned as is" do
      assert {_, %{"error" => %{"code" => -32002}}} =
               rpc("/a2a/research", "CancelTask", %{"id" => "finished"})

      assert {_,
              %{
                "result" => %{
                  "id" => "was-canceled",
                  "status" => %{"state" => "TASK_STATE_CANCELED"}
                }
              }} =
               rpc("/a2a/research", "CancelTask", %{"id" => "was-canceled"})
    end
  end

  describe "SendStreamingMessage" do
    defp user_message(text, extra \\ %{}),
      do:
        Map.merge(
          %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => text}]},
          extra
        )

    test "streams the task, then each event, until the task needs input" do
      {conn, events} =
        stream("/pubsub/a2a/research", "SendStreamingMessage", %{
          "message" => user_message("work")
        })

      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
      assert Enum.map(events, &elem(&1, 0)) == ["1", "2", "3", "4", "5"]
      assert Enum.all?(events, &match?({_, %{"jsonrpc" => "2.0", "id" => 7}}, &1))

      assert [
               %{
                 "task" => %{
                   "id" => task_id,
                   "contextId" => context_id,
                   "status" => %{"state" => "TASK_STATE_SUBMITTED"}
                 }
               },
               %{
                 "statusUpdate" => %{
                   "taskId" => task_id,
                   "contextId" => context_id,
                   "status" => %{"state" => "TASK_STATE_WORKING"}
                 }
               },
               %{
                 "artifactUpdate" => %{
                   "taskId" => task_id,
                   "contextId" => context_id,
                   "append" => false
                 }
               },
               %{
                 "artifactUpdate" => %{
                   "append" => true,
                   "artifact" => %{"parts" => [%{"text" => "- Ages"}]}
                 }
               },
               %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}}
             ] = Enum.map(events, fn {_id, %{"result" => result}} -> result end)
    end

    test "a message is the only event" do
      assert {_conn, [{"1", %{"result" => %{"message" => %{"parts" => [%{"text" => "pong"}]}}}}]} =
               stream("/pubsub/a2a/research", "SendStreamingMessage", %{
                 "message" => user_message("ping")
               })
    end

    test "a finished task is the only event" do
      assert {_conn,
              [
                {"1",
                 %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}}}
              ]} =
               stream("/pubsub/a2a/research", "SendStreamingMessage", %{
                 "message" => user_message("done")
               })
    end

    test "errors before the stream starts are plain JSON-RPC errors" do
      {conn, body} =
        rpc("/pubsub/a2a/research", "SendStreamingMessage", %{
          "message" => %{"role" => "ROLE_USER"}
        })

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
      assert %{"error" => %{"code" => -32602}} = body

      assert {_, %{"error" => %{"code" => -32004, "message" => "Not today"}}} =
               rpc("/pubsub/a2a/research", "SendStreamingMessage", %{
                 "message" => user_message("refuse")
               })
    end
  end

  describe "SubscribeToTask" do
    test "streams the current task, then its events until it finishes" do
      {_conn, events} = stream("/pubsub/a2a/research", "SubscribeToTask", %{"id" => "live"})

      assert [
               %{"task" => %{"id" => "live", "status" => %{"state" => "TASK_STATE_WORKING"}}},
               %{
                 "artifactUpdate" => %{
                   "taskId" => "live",
                   "contextId" => "ctx-1",
                   "artifact" => %{"artifactId" => "out"}
                 }
               },
               %{
                 "statusUpdate" => %{
                   "taskId" => "live",
                   "status" => %{"state" => "TASK_STATE_COMPLETED"}
                 }
               }
             ] = Enum.map(events, fn {_id, %{"result" => result}} -> result end)
    end

    test "an idle stream sends keepalive comments" do
      {conn, events} = stream("/keepalive/a2a/research", "SubscribeToTask", %{"id" => "slow"})

      assert conn.resp_body =~ ": keepalive\n\n"

      assert [
               %{"task" => _},
               %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}
             ] =
               Enum.map(events, fn {_id, %{"result" => result}} -> result end)
    end

    test "events already in the current task aren't sent again" do
      {_conn, events} = stream("/pubsub/a2a/research", "SubscribeToTask", %{"id" => "raced"})

      assert [
               %{"task" => %{"artifacts" => [%{"parts" => [%{"text" => "a"}]}]}},
               %{"statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}
             ] = Enum.map(events, fn {_id, %{"result" => result}} -> result end)
    end

    test "a task waiting on the client is sent, then the stream closes" do
      assert {_conn,
              [
                {"1",
                 %{
                   "result" => %{
                     "task" => %{"status" => %{"state" => "TASK_STATE_INPUT_REQUIRED"}}
                   }
                 }}
              ]} =
               stream("/pubsub/a2a/research", "SubscribeToTask", %{"id" => "t-7"})
    end

    test "finished, missing, and unsupported" do
      assert {_, %{"error" => %{"code" => -32004}}} =
               rpc("/pubsub/a2a/research", "SubscribeToTask", %{"id" => "finished"})

      assert {_, %{"error" => %{"code" => -32001}}} =
               rpc("/pubsub/a2a/research", "SubscribeToTask", %{"id" => "missing"})

      assert {_, %{"error" => %{"code" => -32004}}} =
               rpc("/a2a/research", "SubscribeToTask", %{"id" => "live"})

      assert {_, %{"error" => %{"code" => -32602}}} =
               rpc("/pubsub/a2a/research", "SubscribeToTask", %{})
    end
  end

  describe "ListTasks" do
    test "passes the filter to the agent and pages its answer" do
      {_conn, body} =
        rpc("/a2a/research", "ListTasks", %{
          "contextId" => "ctx-1",
          "status" => "TASK_STATE_COMPLETED",
          "pageSize" => 2,
          "statusTimestampAfter" => "2026-10-27T12:00:00Z",
          "historyLength" => 1
        })

      assert_received {:list_filter,
                       %{
                         context_id: "ctx-1",
                         status: :completed,
                         page_size: 2,
                         page_token: nil,
                         status_timestamp_after: ~U[2026-10-27 12:00:00Z]
                       }}

      assert %{
               "result" => %{
                 "tasks" => [%{"id" => "a", "history" => [%{}]} = a, %{"id" => "b"}],
                 "nextPageToken" => "page-2",
                 "pageSize" => 2,
                 "totalSize" => 3
               }
             } = body

      refute Map.has_key?(a, "artifacts")
    end

    test "defaults, the last page, and includeArtifacts" do
      {_conn, body} =
        rpc("/a2a/research", "ListTasks", %{"pageToken" => "page-2", "includeArtifacts" => true})

      assert_received {:list_filter,
                       %{context_id: nil, status: nil, page_size: 50, page_token: "page-2"}}

      assert %{
               "result" => %{
                 "tasks" => [%{"artifacts" => [%{"artifactId" => "out"}]}, _],
                 "nextPageToken" => "",
                 "pageSize" => 50
               }
             } = body
    end

    test "rejects invalid parameters, and agents without list_tasks/2" do
      for params <- [
            %{"pageSize" => 0},
            %{"pageSize" => 101},
            %{"status" => "TASK_STATE_BORED"},
            %{"statusTimestampAfter" => "yesterday"}
          ] do
        assert {_, %{"error" => %{"code" => -32602}}} = rpc("/a2a/research", "ListTasks", params)
      end

      assert {_, %{"error" => %{"code" => -32004}}} = rpc("/a2a/teams/minimal", "ListTasks", %{})
    end
  end
end

defmodule Phantom.A2A.ConformanceTest.Agent do
  use Phantom.A2A.Agent,
    name: "Conformance",
    description: "Exercises the protocol's edges",
    push_notifications: true,
    extended_card: true

  alias Phantom.A2A.{Artifact, Message, Part, Task, TaskStatus}

  skill :untagged, description: "A skill declared without tags"

  def handle_message(%Message{parts: [%Part{text: "poison"}]}, ctx) do
    ref = ctx.task_ref

    spawn(fn ->
      Phantom.A2A.publish(ref, Task.status(:working, nil, metadata: %{bad: {:tuple}}))
    end)

    {:reply, Task.submitted(ctx), ctx}
  end

  # Waits for a credential sent out of band, then carries on (§7.6.1).
  def handle_message(%Message{parts: [%Part{text: "auth"}]}, ctx) do
    ref = ctx.task_ref

    spawn(fn ->
      Phantom.A2A.publish(ref, Task.status(:auth_required, "Sign in"))
      Phantom.A2A.publish(ref, Task.status(:completed, "Done"))
    end)

    {:reply, Task.submitted(ctx), ctx}
  end

  def handle_message(%Message{parts: [%Part{text: "say"}]}, ctx) do
    ref = ctx.task_ref
    spawn(fn -> Phantom.A2A.publish(ref, Task.status(:completed, "Done")) end)
    {:reply, Task.submitted(ctx), ctx}
  end

  def handle_message(%Message{parts: [%Part{text: "history"}]}, ctx) do
    {:reply,
     Task.submitted(ctx,
       status: %TaskStatus{state: :completed},
       history: [Message.user("one"), Message.user("two")]
     ), ctx}
  end

  def handle_message(%Message{parts: [%Part{text: "poll"}]} = _message, ctx) do
    send(self(), :handled)
    :persistent_term.put({__MODULE__, ctx.task_ref.task_id}, :completed)
    {:reply, Task.submitted(ctx), ctx}
  end

  def handle_message(_message, ctx) do
    send(self(), :handled)
    {:reply, Task.submitted(ctx), ctx}
  end

  def get_task("authing", %{task_ref: %Phantom.A2A.TaskRef{} = ref}) do
    spawn(fn -> Phantom.A2A.publish(ref, Task.status(:completed)) end)
    {:ok, task("authing", :auth_required)}
  end

  def get_task("stored-status", _ctx) do
    {:ok,
     %Task{
       id: "stored-status",
       context_id: "ctx-1",
       status: %TaskStatus{state: :working, message: Message.agent("Reading")}
     }}
  end

  def get_task(id, _ctx) do
    case :persistent_term.get({__MODULE__, id}, nil) do
      nil when id in ["a:b", "a:subscribe", "working"] -> {:ok, task(id, :working)}
      nil -> {:error, :not_found}
      state -> {:ok, task(id, state)}
    end
  end

  def list_tasks(%{page_token: nil}, _ctx),
    do: {:ok, %{tasks: [task("a", :completed)], next_page_token: "2"}}

  def list_tasks(_filter, _ctx), do: {:ok, %{tasks: [task("b", :completed)]}}

  def list_push_configs(_task_id, _ctx), do: {:ok, []}

  defp task(id, state),
    do: %Task{
      id: id,
      context_id: "ctx-1",
      status: %TaskStatus{state: state},
      artifacts: [Artifact.new("out", [Part.text(id)])]
    }
end

defmodule Phantom.A2A.ConformanceTest.NoStore do
  use Phantom.A2A.Agent, name: "No store", description: "Keeps no tasks"

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Task.submitted(ctx), ctx}
end

defmodule Phantom.A2A.ConformanceTest.Resolved do
  use Phantom.A2A.Agent, name: "Resolved", description: "Resolved per organization"

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Message.agent("ok"), ctx}

  def resolve(%{"org" => org}, _session) do
    {:ok,
     %Phantom.A2A.Card{
       name: "Private to #{org}",
       description: "Only for #{org}",
       default_input_modes: ["text/plain"],
       default_output_modes: ["text/plain"]
     }, org}
  end
end

defmodule Phantom.A2A.ConformanceTest.Router do
  use Phantom.Router, name: "Conformance", vsn: "1.0"

  agent "agent", Phantom.A2A.ConformanceTest.Agent
  agent "nostore", Phantom.A2A.ConformanceTest.NoStore
  agent "orgs/:org", Phantom.A2A.ConformanceTest.Resolved, :resolve

  def connect(session, _conn), do: {:ok, session}
end

defmodule Phantom.A2A.ConformanceTest.AnonymousRouter do
  use Phantom.Router, name: "Anonymous", vsn: "1.0"

  agent "agent", Phantom.A2A.ConformanceTest.Agent
end

defmodule Phantom.A2A.ConformanceTest do
  use ExUnit.Case, async: true

  alias Phantom.A2A.{Card, Error, Message, Part, PushConfig, Task, TaskStatus}
  alias Phantom.A2A.ConformanceTest.{AnonymousRouter, Router}

  @pubsub Phantom.A2A.ConformanceTest.PubSub

  setup_all do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    :ok
  end

  defp plug(opts), do: Phantom.A2A.Plug.init([router: Router, pubsub: @pubsub] ++ opts)

  defp rpc(method, params, opts \\ []) do
    {path, opts} = Keyword.pop(opts, :path, "/agent")
    {version, opts} = Keyword.pop(opts, :version, "1.0")
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    :post
    |> Plug.Test.conn(path, JSON.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&if version, do: Plug.Conn.put_req_header(&1, "a2a-version", version), else: &1)
    |> Phantom.A2A.Plug.call(plug(opts))
  end

  defp rpc_json(method, params, opts \\ []),
    do: JSON.decode!(rpc(method, params, opts).resp_body)

  defp rest(verb, path, opts \\ []) do
    verb
    |> Plug.Test.conn(path)
    |> Plug.Conn.put_req_header("a2a-version", "1.0")
    |> Phantom.A2A.Plug.call(plug(opts))
  end

  defp user_message(text \\ "go", extra \\ %{}) do
    Map.merge(
      %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => text}]},
      extra
    )
  end

  defp frames(conn) do
    for frame <- String.split(conn.resp_body, "\n\n", trim: true),
        "data: " <> data <- String.split(frame, "\n") do
      JSON.decode!(data)
    end
  end

  describe "events in a shared process" do
    test "an event for another task doesn't change this request's task" do
      send(self(), {:phantom_a2a_event, "another-task", Task.status(:completed, "Not yours")})

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_SUBMITTED"}}}} =
               rpc_json("SendMessage", %{"message" => user_message()}, blocking_timeout: 30)
    end

    test "a request leaves no events behind for the next one on the connection" do
      send(self(), {:phantom_a2a_event, "another-task", Task.status(:completed)})
      send(self(), {:"$gen_cast", {:task_updated, "another-task"}})

      rpc_json("SendMessage", %{"message" => user_message()}, blocking_timeout: 1)

      refute_received {:phantom_a2a_event, _task_id, _event}
      refute_received {:"$gen_cast", {:task_updated, _task_id}}
    end
  end

  describe "a failure while streaming" do
    @tag :capture_log
    test "ends the stream with an error event, not a second response" do
      conn = rpc("SendStreamingMessage", %{"message" => user_message("poison")})

      assert conn.status == 200

      # The rescue only holds the conn from before the stream, so this is all
      # the test adapter reports. A second response would have raised instead.
      assert [%{"error" => %{"code" => -32603}}] = frames(conn)
    end
  end

  describe "a failure while streaming, over a real connection" do
    @tag :capture_log
    test "writes the task, then the error, in one response" do
      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "SendStreamingMessage",
          "params" => %{"message" => user_message("poison")}
        })

      server =
        start_supervised!(
          {Bandit,
           plug: {Phantom.A2A.Plug, router: Router, pubsub: @pubsub},
           ip: :loopback,
           port: 0,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      :ok =
        :gen_tcp.send(socket, [
          "POST /agent HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n",
          "a2a-version: 1.0\r\ncontent-type: application/json\r\n",
          "content-length: #{byte_size(body)}\r\n\r\n",
          body
        ])

      response = read_all(socket, "")

      assert length(String.split(response, "HTTP/1.1 ")) == 2
      assert response =~ ~s("task":)
      assert response =~ ~s("code":-32603)

      assert elem(:binary.match(response, ~s("task":)), 0) <
               elem(:binary.match(response, ~s("code":-32603)), 0)
    end

    defp read_all(socket, acc) do
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> read_all(socket, acc <> data)
        {:error, :closed} -> acc
      end
    end
  end

  describe "agent card caching" do
    test "a resolved card is private to the client" do
      conn = rest(:get, "/orgs/acme/agent-card.json")

      assert conn.status == 200
      assert [cache_control] = Plug.Conn.get_resp_header(conn, "cache-control")
      assert String.starts_with?(cache_control, "private")
    end

    test "a static card stays public" do
      conn = rest(:get, "/agent/agent-card.json")
      assert [cache_control] = Plug.Conn.get_resp_header(conn, "cache-control")
      assert String.starts_with?(cache_control, "public")
    end
  end

  describe "agent card contents" do
    test "required arrays have at least one element" do
      for path <- ["/nostore/agent-card.json", "/agent/agent-card.json"] do
        card = JSON.decode!(rest(:get, path).resp_body)

        assert [_ | _] = card["skills"]
        assert Enum.all?(card["skills"], &match?([_ | _], &1["tags"]))
      end
    end
  end

  describe "HTTP+JSON path segments" do
    test "task IDs are percent-decoded" do
      assert %{"id" => "a:b"} = JSON.decode!(rest(:get, "/agent/tasks/a%3Ab").resp_body)
    end

    test "an encoded colon in an ID isn't read as a verb" do
      assert %{"id" => "a:subscribe"} =
               JSON.decode!(rest(:get, "/agent/tasks/a%3Asubscribe").resp_body)
    end

    test "a malformed escape doesn't raise" do
      assert rest(:get, "/agent/tasks/a%zz").status == 404
    end
  end

  describe "invalid parameters" do
    test "a non-scalar query parameter is rejected" do
      assert rest(:get, "/agent/tasks?pageSize[a]=1").status == 400
      assert rest(:get, "/agent/tasks/working?historyLength[a]=1").status == 400
    end

    for {name, configuration} <- [
          {"configuration", "x"},
          {"historyLength", %{"historyLength" => "x"}},
          {"negative historyLength", %{"historyLength" => -1}},
          {"returnImmediately", %{"returnImmediately" => "yes"}},
          {"acceptedOutputModes", %{"acceptedOutputModes" => "text/plain"}},
          {"taskPushNotificationConfig", %{"taskPushNotificationConfig" => "x"}}
        ] do
      test "SendMessage rejects #{name} before the handler runs" do
        params = %{
          "message" => user_message(),
          "configuration" => unquote(Macro.escape(configuration))
        }

        assert %{"error" => %{"code" => -32602}} = rpc_json("SendMessage", params)
        refute_received :handled
      end
    end

    test "GetTask rejects a non-integer historyLength" do
      assert %{"error" => %{"code" => -32602}} =
               rpc_json("GetTask", %{"id" => "working", "historyLength" => "x"})
    end

    test "ListTasks rejects non-string filters" do
      assert %{"error" => %{"code" => -32602}} = rpc_json("ListTasks", %{"contextId" => 1})
      assert %{"error" => %{"code" => -32602}} = rpc_json("ListTasks", %{"pageToken" => %{}})
    end

    for {name, extra} <- [
          {"empty parts", %{"parts" => []}},
          {"a part with two kinds of content",
           %{"parts" => [%{"text" => "x", "url" => "https://x.test"}]}},
          {"a non-string contextId", %{"contextId" => 1}},
          {"a non-string taskId", %{"taskId" => %{}}},
          {"non-object metadata", %{"metadata" => "x"}},
          {"non-list extensions", %{"extensions" => "x"}}
        ] do
      test "SendMessage rejects #{name}" do
        message = user_message("go", unquote(Macro.escape(extra)))

        assert %{"error" => %{"code" => -32602}} =
                 rpc_json("SendMessage", %{"message" => message})

        refute_received :handled
      end
    end
  end

  describe "A2A-Version" do
    test "must match the major and minor version" do
      assert %{"error" => %{"code" => -32009}} =
               rpc_json("GetTask", %{"id" => "working"}, version: "1.9")

      assert %{"result" => %{"id" => "working"}} =
               rpc_json("GetTask", %{"id" => "working"}, version: "1.0")
    end

    test "may be a request parameter" do
      assert %{"result" => %{"id" => "working"}} =
               rpc_json("GetTask", %{"id" => "working"},
                 path: "/agent?A2A-Version=1.0",
                 version: nil
               )

      assert %{"error" => %{"code" => -32009}} =
               rpc_json("GetTask", %{"id" => "working"},
                 path: "/agent?A2A-Version=0.3",
                 version: nil
               )
    end
  end

  describe "history" do
    test "historyLength applies to the task a stream starts with" do
      conn =
        rpc("SendStreamingMessage", %{
          "message" => user_message("history"),
          "configuration" => %{"historyLength" => 1}
        })

      assert [%{"result" => %{"task" => %{"history" => [%{"parts" => [%{"text" => "two"}]}]}}}] =
               frames(conn)
    end

    test "is omitted when there is none to return" do
      assert %{"result" => %{"task" => task}} =
               rpc_json("SendMessage", %{
                 "message" => user_message("history"),
                 "configuration" => %{"historyLength" => 0}
               })

      refute Map.has_key?(task, "history")
    end
  end

  describe "AUTH_REQUIRED" do
    test "a stream stays open until the task finishes" do
      conn = rpc("SendStreamingMessage", %{"message" => user_message("auth")})

      assert [
               %{"result" => %{"task" => _}},
               %{
                 "result" => %{
                   "statusUpdate" => %{"status" => %{"state" => "TASK_STATE_AUTH_REQUIRED"}}
                 }
               },
               %{
                 "result" => %{
                   "statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}
                 }
               }
             ] = frames(conn)
    end

    test "a subscription to a task waiting on auth stays open" do
      conn = rpc("SubscribeToTask", %{"id" => "authing"})

      assert [
               %{
                 "result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_AUTH_REQUIRED"}}}
               },
               %{
                 "result" => %{
                   "statusUpdate" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}
                 }
               }
             ] = frames(conn)
    end

    test "a blocking SendMessage returns at once so the client can authenticate" do
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_AUTH_REQUIRED"}}}} =
               rpc_json("SendMessage", %{"message" => user_message("auth")})
    end
  end

  describe "status messages" do
    test "carry the task and context IDs in a stream" do
      conn = rpc("SendStreamingMessage", %{"message" => user_message("say")})

      assert [
               %{"result" => %{"task" => %{"id" => id, "contextId" => context_id}}},
               %{
                 "result" => %{
                   "statusUpdate" => %{
                     "status" => %{"message" => %{"taskId" => id, "contextId" => context_id}}
                   }
                 }
               }
             ] = frames(conn)
    end

    test "carry the task and context IDs on a stored task" do
      assert %{
               "result" => %{
                 "status" => %{
                   "message" => %{"taskId" => "stored-status", "contextId" => "ctx-1"}
                 }
               }
             } = rpc_json("GetTask", %{"id" => "stored-status"})
    end
  end

  describe "blocking SendMessage without pubsub" do
    test "polls the agent's store until the task settles" do
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               rpc_json("SendMessage", %{"message" => user_message("poll")},
                 pubsub: nil,
                 poll_interval: 1,
                 blocking_timeout: 1_000
               )
    end

    test "returns at once when the agent stores no tasks" do
      {elapsed, body} =
        :timer.tc(fn ->
          rpc_json("SendMessage", %{"message" => user_message()},
            path: "/nostore",
            pubsub: nil,
            poll_interval: 1,
            blocking_timeout: 5_000
          )
        end)

      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_SUBMITTED"}}}} =
               body

      assert elapsed < 1_000_000
    end

    test "polls once more at the deadline" do
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               rpc_json("SendMessage", %{"message" => user_message("poll")},
                 pubsub: nil,
                 poll_interval: 60_000,
                 blocking_timeout: 10
               )
    end
  end

  describe "blocking_timeout: :infinity" do
    test "waits on events with no deadline" do
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               rpc_json("SendMessage", %{"message" => user_message("say")},
                 blocking_timeout: :infinity
               )
    end

    test "polls with no deadline" do
      assert %{"result" => %{"task" => %{"status" => %{"state" => "TASK_STATE_COMPLETED"}}}} =
               rpc_json("SendMessage", %{"message" => user_message("poll")},
                 pubsub: nil,
                 poll_interval: 1,
                 blocking_timeout: :infinity
               )
    end
  end

  describe "ListTasks totalSize" do
    test "is not guessed from a page when more pages follow" do
      assert %{"error" => %{"code" => -32006}} = rpc_json("ListTasks", %{})
    end

    test "is the page's length on the last page" do
      assert %{"result" => %{"totalSize" => 1}} = rpc_json("ListTasks", %{"pageToken" => "2"})
    end
  end

  describe "push config pageSize" do
    test "isn't capped as ListTasks is" do
      assert %{"result" => %{"configs" => []}} =
               rpc_json("ListTaskPushNotificationConfigs", %{
                 "taskId" => "working",
                 "pageSize" => 500
               })
    end
  end

  describe "GetExtendedAgentCard" do
    test "needs a router that authenticates" do
      assert %{"error" => %{"code" => -32007}} =
               rpc_json("GetExtendedAgentCard", %{}, router: AnonymousRouter)
    end

    test "is served once connect/2 is implemented" do
      assert %{"result" => %{"name" => "Conformance"}} = rpc_json("GetExtendedAgentCard", %{})
    end
  end

  describe "decoding what a peer sends" do
    test "a task may have no contextId" do
      assert {:ok, %Task{id: "t1", context_id: nil}} =
               Task.from_json(%{"id" => "t1", "status" => %{"state" => "TASK_STATE_WORKING"}})
    end

    test "a task with a non-string contextId is an error" do
      assert {:error, _} =
               Task.from_json(%{
                 "id" => "t1",
                 "contextId" => 1,
                 "status" => %{"state" => "TASK_STATE_WORKING"}
               })
    end

    test "a non-string timestamp is an error" do
      assert {:error, _} =
               TaskStatus.from_json(%{"state" => "TASK_STATE_WORKING", "timestamp" => 5})
    end

    test "malformed errors are invalid agent responses" do
      for error <- ["x", %{}, %{"code" => "x", "message" => 1}, %{"message" => 1}, 5] do
        assert %Error{code: -32006} = Error.from_json(error)
      end
    end

    test "error details that aren't a list are ignored" do
      assert %Error{code: -32603, message: "m"} =
               Error.from_json(%{"message" => "m", "details" => "x"})
    end

    test "a card with malformed fields is an error" do
      for field <- [
            %{"supportedInterfaces" => "x"},
            %{"capabilities" => "x"},
            %{"capabilities" => %{"extensions" => "x"}},
            %{"capabilities" => %{"extensions" => ["x"]}}
          ] do
        assert {:error, _} = Card.from_json(Map.put(field, "name", "n"))
      end
    end

    test "push configs need string fields" do
      url = "https://x.test/hook"

      for field <- [%{"token" => %{}}, %{"id" => 1}, %{"taskId" => 1}, %{"tenant" => 1}] do
        assert {:error, _} = PushConfig.from_json(Map.put(field, "url", url))
      end

      assert {:error, _} =
               PushConfig.from_json(%{
                 "url" => url,
                 "authentication" => %{"scheme" => "Bearer", "credentials" => 1}
               })
    end

    test "a part has exactly one kind of content" do
      assert {:error, _} = Part.from_json(%{"text" => "a", "data" => %{}})
      assert {:error, _} = Part.from_json(%{})
      assert {:ok, %Part{text: "a"}} = Part.from_json(%{"text" => "a", "data" => nil})
    end

    test "a message needs at least one part" do
      assert {:error, _} =
               Message.from_json(%{"messageId" => "m", "role" => "ROLE_USER", "parts" => []})
    end
  end
end

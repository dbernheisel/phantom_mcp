defmodule Phantom.A2A.ClientTest.Agent do
  use Phantom.A2A.Agent,
    name: "Client test",
    description: "Answers the client",
    push_notifications: true,
    extended_card: true

  alias Phantom.A2A.{Artifact, Message, Part, Task, TaskStatus}

  @table Phantom.A2A.ClientTest

  def handle_message(%Message{parts: [%Part{text: "work"}]}, ctx) do
    ref = ctx.task_ref

    spawn(fn ->
      Phantom.A2A.publish(ref, Task.status(:working, "Working"))
      Phantom.A2A.publish(ref, Artifact.update("out", [Part.text("done")]))
      Phantom.A2A.publish(ref, Task.status(:completed))
    end)

    {:reply, Task.submitted(ctx), ctx}
  end

  def handle_message(%Message{parts: [%Part{text: text}]}, ctx),
    do: {:reply, Message.agent("echo: #{text}"), ctx}

  def get_task("missing", _ctx), do: {:error, :not_found}

  def get_task("live", %{task_ref: ref}) do
    spawn(fn -> Phantom.A2A.publish(ref, Task.status(:completed)) end)
    {:ok, task("live", :working)}
  end

  def get_task(id, _ctx), do: {:ok, task(id, :working)}
  def cancel_task(task, _ctx), do: {:ok, %{task | status: %TaskStatus{state: :canceled}}}

  def list_tasks(filter, _ctx) do
    {:ok,
     %{
       tasks: [task("a", :completed)],
       next_page_token: if(filter.page_token, do: nil, else: "2"),
       total_size: 2
     }}
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
    do: {:ok, for({_, c} <- :ets.lookup(@table, task_id), do: c)}

  def delete_push_config(task_id, id, _ctx) do
    :ets.match_delete(@table, {task_id, %{id: id}})
    :ok
  end

  def extended_card(card, _ctx), do: {:ok, %{card | name: "Client test (extended)"}}

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

defmodule Phantom.A2A.ClientTest.Plain do
  use Phantom.A2A.Agent, name: "Plain", description: "No optional capabilities"

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Message.agent("plain"), ctx}
end

defmodule Phantom.A2A.ClientTest.Router do
  use Phantom.Router, name: "Client test", vsn: "1.0", a2a: [well_known: "agent"]

  agent "agent", Phantom.A2A.ClientTest.Agent
  agent "plain", Phantom.A2A.ClientTest.Plain
end

defmodule Phantom.A2A.ClientTest do
  use ExUnit.Case, async: false

  alias Phantom.A2A.{Client, Error, Message, PushConfig, StatusUpdate, Task}
  alias Phantom.A2A.ClientTest.Router

  setup_all do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    :ets.new(__MODULE__, [:named_table, :public, :bag])
    :ets.give_away(__MODULE__, owner, nil)
    start_supervised!({Phoenix.PubSub, name: Phantom.A2A.ClientTest.PubSub})
    :ok
  end

  setup do
    :ets.delete_all_objects(__MODULE__)
    :ok
  end

  @plug {Phantom.A2A.Plug, router: Router, pubsub: Phantom.A2A.ClientTest.PubSub, mount: ""}

  defp client(binding, path \\ "agent", plug \\ @plug) do
    {:ok, client} =
      Client.new("http://agent.test/#{path}/agent-card.json",
        bindings: [binding],
        req_options: [plug: plug]
      )

    client
  end

  test "finds the card at the well-known path of a URL" do
    assert {:ok, %Client{card: %{name: "Client test"}, url: "http://agent.test/agent"}} =
             Client.new("http://agent.test", req_options: [plug: @plug])
  end

  test "prefers the first binding the card lists that it was asked for" do
    assert %Client{binding: :jsonrpc} = client(:jsonrpc)
    assert %Client{binding: :http_json} = client(:http_json)

    {:ok, card} =
      Client.get_card("http://agent.test/agent/agent-card.json", req_options: [plug: @plug])

    assert {:error, :no_supported_interface} = Client.new(card, bindings: [:grpc])
  end

  for binding <- [:jsonrpc, :http_json] do
    describe "over #{binding}" do
      @describetag binding: binding

      test "send_message/3 answers with a message or a task", %{binding: binding} do
        client = client(binding)

        assert {:ok, %Message{role: :agent, parts: [%{text: "echo: hi"}]}} =
                 Client.send_message(client, "hi")

        assert {:ok, %Task{status: %{state: :submitted}}} =
                 Client.send_message(client, Message.user("work"), return_immediately: true)

        assert {:ok, %Task{status: %{state: :completed}, artifacts: [%{artifact_id: "out"}]}} =
                 Client.send_message(client, "work")
      end

      test "stream_message/3 streams events", %{binding: binding} do
        {:ok, stream} = Client.stream_message(client(binding), "work")

        assert [
                 %Task{status: %{state: :submitted}},
                 %StatusUpdate{status: %{state: :working}},
                 %Phantom.A2A.ArtifactUpdate{artifact: %{artifact_id: "out"}},
                 %StatusUpdate{status: %{state: :completed}}
               ] = Enum.to_list(stream)
      end

      test "tasks: get, list, cancel, and subscribe", %{binding: binding} do
        client = client(binding)

        assert {:ok, %Task{id: "t1", history: [_]}} =
                 Client.get_task(client, "t1", history_length: 1)

        assert {:ok,
                %{tasks: [%Task{id: "a", artifacts: [_]}], next_page_token: "2", total_size: 2}} =
                 Client.list_tasks(client,
                   context_id: "ctx-1",
                   status: :completed,
                   include_artifacts: true
                 )

        assert {:ok, %{next_page_token: nil}} = Client.list_tasks(client, page_token: "2")
        assert {:ok, %Task{status: %{state: :canceled}}} = Client.cancel_task(client, "t1")

        {:ok, stream} = Client.subscribe(client, "live")

        assert [%Task{id: "live"}, %StatusUpdate{status: %{state: :completed}}] =
                 Enum.to_list(stream)
      end

      test "push notification configs", %{binding: binding} do
        client = client(binding)

        assert {:ok, %PushConfig{id: id, task_id: "t1"}} =
                 Client.create_push_config(client, %PushConfig{
                   task_id: "t1",
                   url: "https://example.com/hook"
                 })

        assert {:ok, %PushConfig{id: ^id}} = Client.get_push_config(client, "t1", id)
        assert {:ok, [%PushConfig{id: ^id}]} = Client.list_push_configs(client, "t1")
        assert :ok = Client.delete_push_config(client, "t1", id)
        assert {:error, %Error{code: -32001}} = Client.get_push_config(client, "t1", id)
      end

      test "get_extended_card/1", %{binding: binding} do
        assert {:ok, %{name: "Client test (extended)"}} =
                 Client.get_extended_card(client(binding))
      end

      test "errors come back as Phantom.A2A.Error", %{binding: binding} do
        assert {:error, %Error{code: -32001, message: "Task not found: missing"}} =
                 Client.get_task(client(binding), "missing")
      end

      test "optional operations need the card's capability", %{binding: binding} do
        # No pubsub, so not even streaming is advertised.
        client = client(binding, "plain", {Phantom.A2A.Plug, router: Router, mount: ""})

        assert {:error, %Error{code: -32004}} = Client.stream_message(client, "hi")
        assert {:error, %Error{code: -32004}} = Client.subscribe(client, "t1")
        assert {:error, %Error{code: -32003}} = Client.list_push_configs(client, "t1")
        assert {:error, %Error{code: -32004}} = Client.get_extended_card(client)
      end
    end
  end

  test "streams over a real connection" do
    {:ok, server} =
      Bandit.start_link(plug: @plug, ip: :loopback, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Client.new("http://127.0.0.1:#{port}/agent/agent-card.json", bindings: [:http_json])

    assert client.url == "http://127.0.0.1:#{port}/agent"
    {:ok, stream} = Client.stream_message(client, "work")

    assert [%Task{}, %StatusUpdate{}, _artifact, %StatusUpdate{status: %{state: :completed}}] =
             Enum.to_list(stream)
  end

  test "sends headers and extensions" do
    test = self()

    plug = fn conn ->
      send(test, {:headers, conn.req_headers})

      Plug.Conn.send_resp(
        conn,
        200,
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{"message" => %{"messageId" => "m", "role" => "ROLE_AGENT", "parts" => []}}
        })
      )
    end

    {:ok, card} =
      Client.get_card("http://agent.test/agent/agent-card.json", req_options: [plug: @plug])

    {:ok, client} =
      Client.new(card,
        bindings: [:jsonrpc],
        headers: [{"authorization", "Bearer t"}],
        extensions: ["https://x.test/ext"],
        req_options: [plug: plug]
      )

    assert {:ok, %Message{}} = Client.send_message(client, "hi")
    assert_received {:headers, headers}
    assert {"a2a-version", "1.0"} in headers
    assert {"authorization", "Bearer t"} in headers
    assert {"a2a-extensions", "https://x.test/ext"} in headers
  end
end

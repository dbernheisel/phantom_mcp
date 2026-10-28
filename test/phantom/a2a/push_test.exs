defmodule Phantom.A2A.PushTest.Agent do
  use Phantom.A2A.Agent,
    name: "Push",
    description: "Pushes task updates",
    push_notifications: true

  alias Phantom.A2A.{Message, Part, Task, TaskStatus}

  @table Phantom.A2A.PushTest

  def handle_message(%Message{parts: [%Part{text: "publish"}]}, ctx) do
    Phantom.A2A.publish(ctx.task_ref, Task.status(:completed, "Done"))
    {:reply, Task.submitted(ctx), ctx}
  end

  def handle_message(_message, ctx), do: {:reply, Task.submitted(ctx), ctx}

  def get_task("missing", _ctx), do: {:error, :not_found}

  def get_task(id, _ctx),
    do: {:ok, %Task{id: id, context_id: "ctx-1", status: %TaskStatus{state: :working}}}

  def create_push_config(config, _ctx) do
    :ets.insert(@table, {config.task_id, config})
    {:ok, config}
  end

  def get_push_config(task_id, id, _ctx) do
    case Enum.find(push_configs(task_id), &(&1.id == id)) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
  end

  def list_push_configs(task_id, _ctx), do: {:ok, push_configs(task_id)}

  def delete_push_config(task_id, id, _ctx) do
    :ets.match_delete(@table, {task_id, %{id: id}})
    :ok
  end

  def push_configs(%Phantom.A2A.TaskRef{task_id: task_id}), do: push_configs(task_id)

  def push_configs(task_id) when is_binary(task_id),
    do: for({_task_id, config} <- :ets.lookup(@table, task_id), do: config)
end

defmodule Phantom.A2A.PushTest.CustomDelivery do
  use Phantom.A2A.Agent,
    name: "Custom delivery",
    description: "Delivers pushes itself",
    push_notifications: true

  alias Phantom.A2A.{PushConfig, Task}

  def handle_message(_message, ctx) do
    Phantom.A2A.publish(ctx.task_ref, Task.status(:completed))
    {:reply, Task.submitted(ctx), ctx}
  end

  def push_configs(ref),
    do: [%PushConfig{id: "c1", task_id: ref.task_id, url: "https://example.com/hook"}]

  def deliver_push(config, event, ref) do
    send(Phantom.A2A.PushTest, {:delivered, config, event, ref})
    :ok
  end
end

defmodule Phantom.A2A.PushTest.Plain do
  use Phantom.A2A.Agent, name: "Plain", description: "No push notifications"

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Task.submitted(ctx), ctx}

  def get_task(id, _ctx),
    do:
      {:ok,
       %Phantom.A2A.Task{
         id: id,
         context_id: "c",
         status: %Phantom.A2A.TaskStatus{state: :working}
       }}
end

defmodule Phantom.A2A.PushTest.Router do
  use Phantom.Router, name: "Push", vsn: "1.0", a2a: [allow_private_push_urls: true]

  agent "push", Phantom.A2A.PushTest.Agent
  agent "custom", Phantom.A2A.PushTest.CustomDelivery
  agent "plain", Phantom.A2A.PushTest.Plain
end

defmodule Phantom.A2A.PushTest.Receiver do
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, test) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test, {:webhook, conn.request_path, conn.req_headers, JSON.decode!(body)})
    Plug.Conn.send_resp(conn, 200, "")
  end
end

defmodule Phantom.A2A.PushTest do
  use ExUnit.Case, async: false

  import Phantom.A2A.Test

  alias Phantom.A2A.{Push, PushConfig}
  alias Phantom.A2A.PushTest.Router

  setup_all do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    :ets.new(__MODULE__, [:named_table, :public, :bag, {:heir, owner, nil}])
    :ets.give_away(__MODULE__, owner, nil)
    :ok
  end

  setup do
    :ets.delete_all_objects(__MODULE__)
    Process.register(self(), __MODULE__)
    :ok
  end

  defp rpc(agent, method, params) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    :post
    |> Plug.Test.conn("/" <> agent, JSON.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("a2a-version", "1.0")
    |> Phantom.A2A.Plug.call(Phantom.A2A.Plug.init(router: Router))
    |> Map.fetch!(:resp_body)
    |> JSON.decode!()
  end

  describe "PushConfig" do
    test "round-trips through ProtoJSON" do
      json = %{
        "id" => "c1",
        "taskId" => "t1",
        "url" => "https://example.com/hook",
        "token" => "tok",
        "authentication" => %{"scheme" => "Bearer", "credentials" => "secret"}
      }

      assert {:ok,
              %PushConfig{
                id: "c1",
                task_id: "t1",
                url: "https://example.com/hook",
                token: "tok",
                authentication: %{scheme: "Bearer", credentials: "secret"}
              } = config} = PushConfig.from_json(json)

      assert PushConfig.to_json(config) == json
      assert {:error, _} = PushConfig.from_json(%{"taskId" => "t1"})
    end
  end

  describe "validate_url/2" do
    test "allows public https URLs" do
      assert :ok = Push.validate_url("https://93.184.216.34/hook")
      assert :ok = Push.validate_url("https://[2606:2800:220:1::1]/hook")
    end

    test "rejects other schemes, plain http, and private addresses" do
      for url <- [
            "ftp://93.184.216.34/hook",
            "http://93.184.216.34/hook",
            "https://127.0.0.1/hook",
            "https://10.1.2.3/hook",
            "https://172.16.0.1/hook",
            "https://192.168.1.1/hook",
            "https://169.254.169.254/latest/meta-data",
            "https://100.64.0.1/hook",
            "https://0.0.0.0/hook",
            "https://[::1]/hook",
            "https://[fd00::1]/hook",
            "https://[fe80::1]/hook",
            "https://[::ffff:127.0.0.1]/hook",
            "https://localhost/hook",
            "not a url"
          ] do
        assert {:error, _reason} = Push.validate_url(url), url
      end
    end

    test "allow_private_networks allows private addresses and plain http" do
      assert :ok = Push.validate_url("http://127.0.0.1:4000/hook", allow_private_networks: true)
    end
  end

  describe "config methods" do
    test "need an agent that supports push notifications" do
      assert %{"capabilities" => %{"pushNotifications" => true}} = get_card(Router, "push")
      assert %{"capabilities" => %{"pushNotifications" => false}} = get_card(Router, "plain")

      assert %{"error" => %{"code" => -32003}} =
               rpc("plain", "CreateTaskPushNotificationConfig", %{
                 "taskId" => "t1",
                 "url" => "https://example.com/hook"
               })
    end

    test "create, get, list, and delete" do
      assert %{"result" => %{"id" => id, "taskId" => "t1", "url" => "https://example.com/hook"}} =
               rpc("push", "CreateTaskPushNotificationConfig", %{
                 "taskId" => "t1",
                 "url" => "https://example.com/hook"
               })

      assert is_binary(id)

      assert %{"result" => %{"id" => ^id}} =
               rpc("push", "GetTaskPushNotificationConfig", %{"taskId" => "t1", "id" => id})

      assert %{"result" => %{"configs" => [%{"id" => ^id}], "nextPageToken" => ""}} =
               rpc("push", "ListTaskPushNotificationConfigs", %{"taskId" => "t1"})

      for _ <- 1..2 do
        assert %{"result" => nil} =
                 rpc("push", "DeleteTaskPushNotificationConfig", %{"taskId" => "t1", "id" => id})
      end

      assert %{"error" => %{"code" => -32001}} =
               rpc("push", "GetTaskPushNotificationConfig", %{"taskId" => "t1", "id" => id})
    end

    test "check the task and the URL" do
      assert %{"error" => %{"code" => -32001}} =
               rpc("push", "CreateTaskPushNotificationConfig", %{
                 "taskId" => "missing",
                 "url" => "https://example.com/hook"
               })

      assert %{"error" => %{"code" => -32602}} =
               rpc("push", "CreateTaskPushNotificationConfig", %{
                 "taskId" => "t1",
                 "url" => "ftp://example.com/hook"
               })

      assert %{"error" => %{"code" => -32602}} =
               rpc("push", "CreateTaskPushNotificationConfig", %{"taskId" => "t1"})

      assert %{"error" => %{"code" => -32001}} =
               rpc("push", "ListTaskPushNotificationConfigs", %{"taskId" => "missing"})
    end

    test "SendMessage creates a config given in its configuration" do
      assert {:task, %{"id" => task_id}} =
               send_message(Router, "push", "hi",
                 configuration: %{
                   "taskPushNotificationConfig" => %{"url" => "https://example.com/hook"}
                 }
               )

      assert [%PushConfig{task_id: ^task_id, url: "https://example.com/hook"}] =
               Phantom.A2A.PushTest.Agent.push_configs(task_id)
    end
  end

  describe "delivery" do
    setup do
      {:ok, pid} =
        Bandit.start_link(
          plug: {Phantom.A2A.PushTest.Receiver, self()},
          ip: :loopback,
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      {:ok, url: "http://127.0.0.1:#{port}/hook"}
    end

    test "publish/2 posts each event to the task's webhooks", %{url: url} do
      {:task, %{"id" => task_id, "contextId" => context_id}} =
        send_message(Router, "push", "submit")

      :ets.insert(
        __MODULE__,
        {task_id,
         %PushConfig{
           id: "c1",
           task_id: task_id,
           url: url,
           token: "tok",
           authentication: %{scheme: "Bearer", credentials: "secret"}
         }}
      )

      ref = %Phantom.A2A.TaskRef{
        router: Router,
        agent_id: "push",
        task_id: task_id,
        context_id: context_id
      }

      :ok = Phantom.A2A.publish(ref, Phantom.A2A.Task.status(:completed, "Done"))

      assert_receive {:webhook, "/hook", headers, body}, 5_000
      assert {"authorization", "Bearer secret"} in headers
      assert {"x-a2a-notification-token", "tok"} in headers
      assert {"content-type", "application/json"} in headers

      assert %{
               "statusUpdate" => %{
                 "taskId" => ^task_id,
                 "contextId" => ^context_id,
                 "status" => %{"state" => "TASK_STATE_COMPLETED"}
               }
             } = body
    end

    test "is checked again, so a URL that became private isn't called", %{url: url} do
      ref = %Phantom.A2A.TaskRef{
        router: Phantom.A2A.PushTest.StrictRouter,
        agent_id: "push",
        task_id: "t9"
      }

      :ets.insert(__MODULE__, {"t9", %PushConfig{id: "c1", task_id: "t9", url: url}})

      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Phantom.A2A.publish(ref, Phantom.A2A.Task.status(:completed))
        refute_receive {:webhook, _, _, _}, 300
      end)
    end

    test "an agent can deliver pushes itself" do
      {:task, %{"id" => task_id}} = send_message(Router, "custom", "go")

      assert_receive {:delivered, %PushConfig{id: "c1"},
                      %Phantom.A2A.StatusUpdate{task_id: ^task_id, context_id: context_id},
                      %Phantom.A2A.TaskRef{task_id: ^task_id}}

      assert is_binary(context_id)
    end
  end
end

defmodule Phantom.A2A.PushTest.StrictRouter do
  use Phantom.Router, name: "Strict"

  agent "push", Phantom.A2A.PushTest.Agent
end

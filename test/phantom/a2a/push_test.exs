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
    start_supervised!({Agent, fn -> :ets.new(__MODULE__, [:named_table, :public, :bag]) end})
    :ok
  end

  setup do
    :ets.delete_all_objects(__MODULE__)
    Process.register(self(), __MODULE__)
    :ok
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end

  defp deliveries do
    for {_id, pid, _type, [Phantom.A2A.Push.Delivery]} <-
          DynamicSupervisor.which_children(Phantom.A2A.PushSupervisor),
        do: pid
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

  describe "validate_url/2 with IPv6 literals" do
    for host <- ~w[::7f00:1 ::1 ::ffff:127.0.0.1 2002:7f00:1:: 2002:a00:1:: 64:ff9b::7f00:1
                   fec0::1 fc00::1 fe80::1 ff02::1 2001:db8::1 2001:0:1::1
                   64:ff9b:1::808:808 ::ffff:0:7f00:1 100::1] do
      test "refuses #{host}" do
        assert {:error, "resolves to a private address"} =
                 Push.validate_url("https://[#{unquote(host)}]/hook")
      end
    end

    test "allows a public address" do
      assert :ok = Push.validate_url("https://[2606:4700:4700::1111]/hook")
      assert :ok = Push.validate_url("https://[2002:808:808::1]/hook")
    end
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

    test "refuses header values with line breaks" do
      url = "https://example.com/hook"

      for json <- [
            %{"url" => url, "token" => "tok\r\nx-injected: 1"},
            %{"url" => url, "authentication" => %{"scheme" => "Bearer\n"}},
            %{"url" => url, "authentication" => %{"scheme" => "Bearer", "credentials" => "a\rb"}}
          ] do
        assert {:error, _} = PushConfig.from_json(json), inspect(json)
      end
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
            "https://192.88.99.1/hook",
            "https://198.51.100.1/hook",
            "https://203.0.113.1/hook",
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
      assert {"content-type", "application/a2a+json"} in headers

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

    test "retries a failed delivery with backoff" do
      test = self()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      plug = fn conn, _opts ->
        attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
        send(test, {:attempt, attempt})
        Plug.Conn.send_resp(conn, if(attempt < 3, do: 503, else: 200), "")
      end

      {:ok, pid} =
        start_supervised(
          {Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false},
          id: :retry_webhook
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      config = %PushConfig{id: "c1", task_id: "t1", url: "http://127.0.0.1:#{port}/hook"}

      ref = %Phantom.A2A.TaskRef{
        router: Phantom.A2A.PushTest.RetryRouter,
        agent_id: "push",
        task_id: "t1"
      }

      assert :ok = Push.deliver_async(config, Phantom.A2A.Task.status(:working), ref)

      assert_receive {:attempt, 1}, 2_000
      assert_receive {:attempt, 2}, 2_000
      assert_receive {:attempt, 3}, 2_000
      refute_receive {:attempt, 4}, 50
    end

    test "waits for a retry without blocking, and can be stopped meanwhile" do
      test = self()

      plug = fn conn, _opts ->
        send(test, :attempt)
        Plug.Conn.send_resp(conn, 503, "")
      end

      {:ok, pid} =
        start_supervised(
          {Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false},
          id: :waiting_webhook
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      config = %PushConfig{id: "c1", task_id: "t1", url: "http://127.0.0.1:#{port}/hook"}

      ref = %Phantom.A2A.TaskRef{
        router: Phantom.A2A.PushTest.SlowRetryRouter,
        agent_id: "push",
        task_id: "t1"
      }

      assert :ok = Push.deliver_async(config, Phantom.A2A.Task.status(:working), ref)
      assert_receive :attempt, 2_000

      assert [delivery] = deliveries()

      assert eventually(fn ->
               match?(%{attempt: :waiting, backoff: []}, :sys.get_state(delivery))
             end)

      monitor = Process.monitor(delivery)
      :ok = DynamicSupervisor.terminate_child(Phantom.A2A.PushSupervisor, delivery)
      assert_receive {:DOWN, ^monitor, :process, ^delivery, _reason}
    end

    test "doesn't retry a request the webhook refuses" do
      test = self()

      plug = fn conn, _opts ->
        send(test, :attempt)
        Plug.Conn.send_resp(conn, 400, "")
      end

      {:ok, pid} =
        start_supervised(
          {Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false},
          id: :refusing_webhook
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      config = %PushConfig{id: "c1", task_id: "t1", url: "http://127.0.0.1:#{port}/hook"}

      ref = %Phantom.A2A.TaskRef{
        router: Phantom.A2A.PushTest.RetryRouter,
        agent_id: "push",
        task_id: "t1"
      }

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Push.deliver_async(config, Phantom.A2A.Task.status(:working), ref)
        assert_receive :attempt, 2_000
        refute_receive :attempt, 100
      end)
    end

    test "reaches a webhook that only has an IPv6 address" do
      {:ok, pid} =
        start_supervised(
          {Bandit,
           plug: {Phantom.A2A.PushTest.Receiver, self()},
           ip: {0, 0, 0, 0, 0, 0, 0, 1},
           port: 0,
           startup_log: false},
          id: :ipv6_webhook
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      config = %PushConfig{id: "c1", task_id: "t1", url: "http://[::1]:#{port}/hook"}

      assert :ok =
               Push.deliver(config, Phantom.A2A.Task.status(:working),
                 allow_private_networks: true
               )

      assert_receive {:webhook, "/hook", _headers, _body}
    end

    test "telemetry gets the config's ID, not its secrets", %{url: url} do
      test = self()
      handler = "push-telemetry-#{inspect(test)}"

      :telemetry.attach(
        handler,
        [:phantom, :a2a, :push, :stop],
        fn _event, _measurements, meta, _config -> send(test, {:telemetry, meta}) end,
        nil
      )

      config = %PushConfig{
        id: "c1",
        task_id: "t1",
        url: url,
        token: "tok-secret",
        authentication: %{scheme: "Bearer", credentials: "cred-secret"}
      }

      assert :ok =
               Push.deliver(config, Phantom.A2A.Task.status(:working),
                 allow_private_networks: true
               )

      assert_receive {:telemetry, %{config_id: "c1", task_id: "t1"} = meta}
      refute inspect(meta) =~ "secret"
    after
      :telemetry.detach("push-telemetry-#{inspect(self())}")
    end

    test "doesn't wait for the webhook's answer body" do
      plug = fn conn, _opts ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("x", 1_000))
        Process.sleep(5_000)
        conn
      end

      {:ok, pid} =
        start_supervised(
          {Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false},
          id: :streaming_webhook
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      config = %PushConfig{id: "c1", task_id: "t1", url: "http://127.0.0.1:#{port}/hook"}

      {time, result} =
        :timer.tc(fn ->
          Push.deliver(config, Phantom.A2A.Task.status(:working), allow_private_networks: true)
        end)

      assert result == :ok
      assert time < 2_000_000
    end

    test "delivers a webhook's events in order, one at a time" do
      test = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      plug = fn conn, _opts ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: Process.sleep(200)
        %{"statusUpdate" => %{"status" => %{"state" => state}}} = JSON.decode!(body)
        send(test, {:state, state})
        Plug.Conn.send_resp(conn, 200, "")
      end

      {:ok, pid} =
        start_supervised(
          {Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false},
          id: :ordered_webhook
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      config = %PushConfig{id: "c1", task_id: "ordered", url: "http://127.0.0.1:#{port}/hook"}

      ref = %Phantom.A2A.TaskRef{
        router: Phantom.A2A.PushTest.RetryRouter,
        agent_id: "push",
        task_id: "ordered"
      }

      for state <- [:submitted, :working, :completed],
          do: assert(:ok = Push.deliver_async(config, Phantom.A2A.Task.status(state), ref))

      assert [_one] = deliveries()

      assert_receive {:state, "TASK_STATE_SUBMITTED"}, 2_000
      assert_receive {:state, "TASK_STATE_WORKING"}, 2_000
      assert_receive {:state, "TASK_STATE_COMPLETED"}, 2_000
    end

    test "keeps a limited number of events for a webhook" do
      plug = fn conn, _opts -> Plug.Conn.send_resp(conn, 503, "") end

      {:ok, pid} =
        start_supervised(
          {Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false},
          id: :full_webhook
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      config = %PushConfig{id: "c1", task_id: "full", url: "http://127.0.0.1:#{port}/hook"}

      ref = %Phantom.A2A.TaskRef{
        router: Phantom.A2A.PushTest.SlowRetryRouter,
        agent_id: "push",
        task_id: "full"
      }

      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..150,
            do: assert(:ok = Push.deliver_async(config, Phantom.A2A.Task.status(:working), ref))
      end)

      assert [delivery] = deliveries()
      assert :queue.len(:sys.get_state(delivery).queue) == 100
      :ok = DynamicSupervisor.terminate_child(Phantom.A2A.PushSupervisor, delivery)
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

defmodule Phantom.A2A.PushTest.RetryRouter do
  use Phantom.Router,
    name: "Retry",
    a2a: [allow_private_push_urls: true, push_retry_backoff: [1, 1, 1]]

  agent "push", Phantom.A2A.PushTest.Agent
end

defmodule Phantom.A2A.PushTest.SlowRetryRouter do
  use Phantom.Router,
    name: "Slow retry",
    a2a: [allow_private_push_urls: true, push_retry_backoff: [:timer.minutes(10)]]

  agent "push", Phantom.A2A.PushTest.Agent
end

defmodule Phantom.A2A.PushTest.StrictRouter do
  use Phantom.Router, name: "Strict"

  agent "push", Phantom.A2A.PushTest.Agent
end

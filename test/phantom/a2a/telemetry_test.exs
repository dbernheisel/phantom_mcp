defmodule Phantom.A2A.TelemetryTest.Agent do
  use Phantom.A2A.Agent, name: "Telemetry", description: "Emits events"

  alias Phantom.A2A.{Message, Part}

  def handle_message(%Message{parts: [%Part{text: "explode"}]}, _ctx), do: raise("boom")
  def handle_message(_message, ctx), do: {:reply, Message.agent("ok"), ctx}
end

defmodule Phantom.A2A.TelemetryTest.Router do
  use Phantom.Router, name: "Telemetry", vsn: "1.0"

  agent "telemetry", Phantom.A2A.TelemetryTest.Agent
end

defmodule Phantom.A2A.TelemetryTest do
  use ExUnit.Case, async: true

  alias Phantom.A2A.TelemetryTest.Router

  setup do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [
        [:phantom, :a2a, :dispatch, :start],
        [:phantom, :a2a, :dispatch, :stop],
        [:phantom, :a2a, :dispatch, :exception],
        [:phantom, :a2a, :push, :start],
        [:phantom, :a2a, :push, :stop]
      ],
      fn event, measurements, meta, _config ->
        if meta[:router] == Router or meta[:url] == "http://127.0.0.1:1/hook",
          do: send(test, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp send_message(text, headers \\ []) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "SendMessage",
      "params" => %{
        "message" => %{"messageId" => "m1", "role" => "ROLE_USER", "parts" => [%{"text" => text}]}
      }
    }

    :post
    |> Plug.Test.conn("/telemetry", JSON.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("a2a-version", "1.0")
    |> then(
      &Enum.reduce(headers, &1, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    )
    |> Phantom.A2A.Plug.call(Phantom.A2A.Plug.init(router: Router))
  end

  test "each request is a dispatch span, with the client's trace context" do
    send_message("hi", [{"traceparent", "00-abc-def-01"}, {"tracestate", "vendor=1"}])

    assert_received {:telemetry, [:phantom, :a2a, :dispatch, :start], %{system_time: _}, meta}

    assert %{
             router: Router,
             agent_id: "telemetry",
             method: "SendMessage",
             params: %{"message" => _},
             session: %Phantom.Session{},
             trace_context: %{traceparent: "00-abc-def-01", tracestate: "vendor=1"}
           } = meta

    assert_received {:telemetry, [:phantom, :a2a, :dispatch, :stop], %{duration: _},
                     %{method: "SendMessage", result: {:ok, %{"message" => _}}}}
  end

  test "a raise is an exception event" do
    assert_raise RuntimeError, "boom", fn -> send_message("explode") end

    assert_received {:telemetry, [:phantom, :a2a, :dispatch, :exception], %{duration: _},
                     %{
                       kind: :error,
                       reason: %RuntimeError{message: "boom"},
                       agent_id: "telemetry"
                     }}
  end

  test "each push delivery is a span" do
    config = %Phantom.A2A.PushConfig{id: "c1", task_id: "t1", url: "http://127.0.0.1:1/hook"}
    event = %{Phantom.A2A.Task.status(:completed) | task_id: "t1", context_id: "c"}

    assert {:error, _reason} =
             Phantom.A2A.Push.deliver(config, event, allow_private_networks: true)

    assert_received {:telemetry, [:phantom, :a2a, :push, :start], _,
                     %{task_id: "t1", config_id: "c1"}}

    assert_received {:telemetry, [:phantom, :a2a, :push, :stop], _, %{result: {:error, _}}}
  end
end

defmodule Phantom.A2A.DynamicTest.Static do
  use Phantom.A2A.Agent, name: "Static", description: "Declared at compile time"

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Message.agent("static"), ctx}
end

defmodule Phantom.A2A.DynamicTest.Hosted do
  use Phantom.A2A.Agent, name: "Hosted", description: "Agents stored per organization"

  alias Phantom.A2A.{AgentSkill, Card, Message}

  @agents %{"triage" => "Device triage", "bench" => "Benchmarking"}

  def resolve(%{"org" => org, "agent_key" => key}, session) do
    case @agents do
      %{^key => name} when org == session.assigns.org ->
        card = %Card{
          name: "#{org} #{name}",
          description: "#{name} for #{org}",
          default_input_modes: ["text/plain"],
          default_output_modes: ["text/plain"],
          skills: [AgentSkill.build(key, description: name)]
        }

        {:ok, card, %{key: key}}

      _ ->
        {:error, :not_found}
    end
  end

  def handle_message(_message, ctx) do
    text =
      "#{ctx.agent.id} #{inspect(ctx.agent.params)} #{inspect(ctx.agent.state)} #{ctx.task_ref.agent_id}"

    {:reply, Message.agent(text), ctx}
  end
end

defmodule Phantom.A2A.DynamicTest.Router do
  use Phantom.Router, name: "Dynamic", vsn: "1.0", a2a: [well_known: "static"]

  agent "static", Phantom.A2A.DynamicTest.Static
  agent ":org/:agent_key", Phantom.A2A.DynamicTest.Hosted, :resolve
  # Declared after the dynamic route, but static routes match first.
  agent "acme/static", Phantom.A2A.DynamicTest.Static

  def connect(session, conn) do
    case Plug.Conn.get_req_header(conn, "x-org") do
      [org] -> {:ok, session |> Phantom.Session.assign(org: org) |> allow(conn)}
      [] -> {:unauthorized, %{method: "Bearer"}}
    end
  end

  defp allow(session, conn) do
    case Plug.Conn.get_req_header(conn, "x-allow") do
      [] -> session
      [allowed] -> Phantom.Session.allow_agents(session, String.split(allowed, ","))
    end
  end
end

defmodule Phantom.A2A.DynamicTest do
  use ExUnit.Case, async: true

  import Phantom.A2A.Test

  alias Phantom.A2A.DynamicTest.Router

  defp as(org, extra \\ []), do: [headers: [{"x-org", org} | extra]]

  describe "agent cards" do
    test "are resolved per request" do
      assert %{
               "name" => "acme Device triage",
               "skills" => [%{"id" => "triage"}],
               "supportedInterfaces" => [%{"url" => "http://www.example.com/acme/triage"}]
             } = get_card(Router, "acme/triage", as("acme"))
    end

    test "need the session the resolver checks" do
      assert %{"error" => %{"message" => "Unauthorized"}} = get_card(Router, "acme/triage")

      assert %{"error" => %{"message" => "Not found"}} =
               get_card(Router, "acme/triage", as("globex"))

      assert %{"error" => %{"message" => "Not found"}} = get_card(Router, "acme/nope", as("acme"))
    end

    test "static routes match first and stay public" do
      assert %{"name" => "Static"} = get_card(Router, "acme/static")
      assert %{"name" => "Static"} = get_card(Router, "static")
    end
  end

  test "handlers get the agent's path, params, and state" do
    assert {:message, %{"parts" => [%{"text" => text}]}} =
             send_message(Router, "acme/bench", "hi", as("acme"))

    assert text ==
             ~s(acme/bench %{"agent_key" => "bench", "org" => "acme"} %{key: "bench"} acme/bench)
  end

  test "an unresolved agent is not found" do
    assert {:error, %{"message" => "Not found"}} =
             send_message(Router, "acme/bench", "hi", as("globex"))
  end

  test "allow_agents/2 takes the route's path or the agent's" do
    for allowed <- [":org/:agent_key", "acme/bench"] do
      assert {:message, _} =
               send_message(Router, "acme/bench", "hi", as("acme", [{"x-allow", allowed}]))
    end

    assert {:error, %{"message" => "Not found"}} =
             send_message(Router, "acme/bench", "hi", as("acme", [{"x-allow", "acme/triage"}]))
  end

  test "routes with params need a resolver" do
    assert_raise ArgumentError, ~r/needs a resolver/, fn ->
      Phantom.Router.agent_route(":org/agent", __MODULE__, [])
    end

    assert %{params?: true, resolver: :resolve} =
             Phantom.Router.agent_route(":org/agent", __MODULE__, :resolve)
  end
end

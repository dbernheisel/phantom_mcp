defmodule Phantom.A2A.ExtendedCardTest.Agent do
  use Phantom.A2A.Agent,
    name: "Extended",
    description: "Shows more to members",
    extended_card: true

  alias Phantom.A2A.AgentSkill

  @description "Anyone can ask"
  skill(:public)

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Message.agent("ok"), ctx}

  def extended_card(_card, %{assigns: %{role: :guest}}),
    do: {:error, Phantom.A2A.Error.invalid_request("Members only")}

  def extended_card(card, ctx) do
    skill = AgentSkill.build(:admin, description: "Only for #{ctx.assigns.role}s")
    {:ok, %{card | skills: card.skills ++ [skill]}}
  end
end

defmodule Phantom.A2A.ExtendedCardTest.Default do
  use Phantom.A2A.Agent, name: "Default", description: "Same card", extended_card: true

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Message.agent("ok"), ctx}
end

defmodule Phantom.A2A.ExtendedCardTest.Router do
  use Phantom.Router, name: "Extended", vsn: "1.0"

  agent "extended", Phantom.A2A.ExtendedCardTest.Agent
  agent "default", Phantom.A2A.ExtendedCardTest.Default

  def connect(session, conn) do
    role = conn |> Plug.Conn.get_req_header("x-role") |> List.first("member")
    {:ok, Phantom.Session.assign(session, role: String.to_existing_atom(role))}
  end
end

defmodule Phantom.A2A.ExtendedCardTest do
  use ExUnit.Case, async: true

  import Phantom.A2A.Test

  alias Phantom.A2A.ExtendedCardTest.Router

  defp extended(agent, opts \\ []) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "GetExtendedAgentCard", "params" => %{}}
    headers = Keyword.get(opts, :headers, [])

    :post
    |> Plug.Test.conn("/" <> agent, JSON.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("a2a-version", "1.0")
    |> then(
      &Enum.reduce(headers, &1, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    )
    |> Phantom.A2A.Plug.call(
      Phantom.A2A.Plug.init([router: Router] ++ Keyword.get(opts, :plug, []))
    )
    |> Map.fetch!(:resp_body)
    |> JSON.decode!()
  end

  test "the public card advertises it" do
    assert %{"capabilities" => %{"extendedAgentCard" => true}} = get_card(Router, "extended")
  end

  test "returns the card the agent builds for the session" do
    assert %{
             "result" => %{
               "name" => "Extended",
               "skills" => [
                 %{"id" => "public"},
                 %{"id" => "admin", "description" => "Only for members"}
               ],
               "supportedInterfaces" => [%{"url" => "http://www.example.com/extended"}],
               "capabilities" => %{"extendedAgentCard" => true}
             }
           } = extended("extended")
  end

  test "the agent can refuse it" do
    assert %{"error" => %{"message" => "Members only"}} =
             extended("extended", headers: [{"x-role", "guest"}])
  end

  test "defaults to the public card" do
    assert %{"result" => %{"name" => "Default"}} = extended("default")
  end

  test "a mount can turn it off" do
    assert %{"error" => %{"code" => -32004}} =
             extended("extended", plug: [extended_card: false])

    assert %{"capabilities" => %{"extendedAgentCard" => false}} =
             :get
             |> Plug.Test.conn("/extended/agent-card.json")
             |> Phantom.A2A.Plug.call(Phantom.A2A.Plug.init(router: Router, extended_card: false))
             |> Map.fetch!(:resp_body)
             |> JSON.decode!()
  end
end

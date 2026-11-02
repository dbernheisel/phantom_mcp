defmodule Phantom.A2A.BridgeTest.Chat do
  use Phantom.A2A.Agent, name: "Chat", description: "Answers free text"

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Message.agent("chatting"), ctx}
end

defmodule Phantom.A2A.BridgeTest.Router do
  @moduledoc "Tools for studies"

  use Phantom.Router, name: "Studies", vsn: "2.0", instructions: @moduledoc

  require Phantom.Tool, as: Tool

  tool :echo, description: "Echo text" do
    field :text, :string, required: true
  end

  tool :stats,
    description: "Study statistics",
    output_schema: %{properties: %{count: %{type: "integer"}}}

  tool :explode, description: "Fails", input_schema: %{}
  tool :secret, description: "Not bridged", input_schema: %{}
  tool :leak, description: "Fails with an internal term", input_schema: %{}

  agent "tools", Phantom.A2A.Bridge, tools: ~w[echo stats explode]
  agent "leaky", Phantom.A2A.Bridge, tools: ~w[leak]
  agent "all", Phantom.A2A.Bridge, name: "Every tool", description: "All of them"
  agent "chat", Phantom.A2A.Bridge, tools: ~w[echo], fallback: Phantom.A2A.BridgeTest.Chat

  def echo(%{"text" => text}, session), do: {:reply, Tool.text("echo: #{text}"), session}
  def stats(_params, session), do: {:reply, Tool.text(%{count: 3}), session}
  def explode(_params, session), do: {:reply, Tool.error("It broke"), session}
  def secret(_params, session), do: {:reply, Tool.text("secret"), session}
  def leak(_params, session), do: {:error, {:db, "postgres://admin:hunter2@db"}, session}

  def connect(session, conn) do
    case Plug.Conn.get_req_header(conn, "x-tools") do
      [tools] -> {:ok, Phantom.Session.allow_tools(session, String.split(tools, ","))}
      [] -> {:ok, session}
    end
  end
end

defmodule Phantom.A2A.BridgeTest do
  use ExUnit.Case, async: true

  import Phantom.A2A.Test

  alias Phantom.A2A.{Message, Part}
  alias Phantom.A2A.BridgeTest.Router

  @extension "https://github.com/dbernheisel/phantom_mcp/a2a/extensions/mcp-tools/v1"

  defp call(agent, tool, args, opts \\ []),
    do:
      send_message(
        Router,
        agent,
        Message.user([Part.data(%{"tool" => tool, "arguments" => args})]),
        opts
      )

  test "the card lists the bridged tools as skills, with their schemas" do
    card = get_card(Router, "tools")

    assert %{
             "name" => "Studies",
             "description" => "Tools for studies",
             "version" => "2.0",
             "skills" => [
               %{"id" => "echo", "description" => "Echo text"},
               %{"id" => "explode"},
               %{"id" => "stats"}
             ],
             "capabilities" => %{
               "extensions" => [%{"uri" => @extension, "params" => %{"tools" => tools}}]
             }
           } = card

    assert [%{"name" => "echo", "inputSchema" => %{"required" => ["text"]}}, _, _] = tools
  end

  test "names, descriptions, and every tool by default" do
    assert %{"name" => "Every tool", "description" => "All of them", "skills" => skills} =
             get_card(Router, "all")

    assert Enum.map(skills, & &1["id"]) == ~w[echo explode leak secret stats]
  end

  test "a data part naming a tool calls it" do
    assert {:message, %{"role" => "ROLE_AGENT", "parts" => [%{"text" => "echo: hi"}]}} =
             call("tools", "echo", %{"text" => "hi"})
  end

  test "structured content is a data part" do
    assert {:message, %{"parts" => parts}} = call("tools", "stats", %{})
    assert %{"data" => %{"count" => 3}} in parts
  end

  test "a tool error is flagged in the metadata" do
    assert {:message,
            %{"parts" => [%{"text" => "It broke"}], "metadata" => %{"mcp/isError" => true}}} =
             call("tools", "explode", %{})
  end

  test "arguments are validated, and only bridged, allowed tools run" do
    assert {:error, %{"code" => -32602}} = call("tools", "echo", %{})

    assert {:error, %{"code" => -32602, "message" => "Unknown tool: secret"}} =
             call("tools", "secret", %{})

    assert {:error, %{"code" => _}} =
             call("tools", "echo", %{"text" => "hi"}, headers: [{"x-tools", "stats"}])
  end

  test "an internal error doesn't reach the client" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, %{"code" => -32603} = error} = call("leaky", "leak", %{})
      refute JSON.encode!(error) =~ "hunter2"
    end)
  end

  test "free text goes to the fallback, or gets the list of tools" do
    assert {:message, %{"parts" => [%{"text" => "chatting"}]}} =
             send_message(Router, "chat", "hello")

    assert {:message, %{"parts" => [%{"text" => help}]}} = send_message(Router, "tools", "hello")
    assert help =~ ~s("tool")
    assert help =~ "echo, explode, stats"
  end

  test "Phantom's client finds the tools on the card and calls one" do
    alias Phantom.A2A.Client

    {:ok, client} =
      Client.new("http://agent.test/tools/agent-card.json",
        bindings: [:http_json],
        req_options: [plug: {Phantom.A2A.Plug, router: Router, mount: ""}]
      )

    %{params: %{"tools" => tools}} =
      Enum.find(client.card.extensions, &(&1.uri == Phantom.A2A.Bridge.extension()))

    assert "echo" in Enum.map(tools, & &1["name"])

    assert {:ok, %Message{parts: [%Part{text: "echo: from the client"}]}} =
             Client.send_message(
               client,
               Message.user([
                 Part.data(%{"tool" => "echo", "arguments" => %{"text" => "from the client"}})
               ])
             )
  end
end

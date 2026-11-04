defmodule Phantom.A2A.CallToolTest.Router do
  use Phantom.Router, name: "Call tool", vsn: "1.0"

  require Phantom.Tool, as: Tool

  tool :echo, description: "Echo text" do
    field :text, :string, required: true
  end

  tool :async_echo, description: "Echo text from another process" do
    field :text, :string, required: true
  end

  @description "Ask the user for their name"
  tool :ask_name, []

  agent "assistant", Phantom.A2A.CallToolTest.Assistant

  def echo(%{"text" => text}, session),
    do: {:reply, Tool.text("#{session.assigns.user}: #{text}"), session}

  def async_echo(%{"text" => text}, session) do
    Task.start(fn -> Phantom.Session.respond(session, Tool.text("later: #{text}")) end)
    {:noreply, session}
  end

  def ask_name(_params, session) do
    elicit =
      Phantom.Elicit.form(%{message: "Name?", requested_schema: [%{name: "name", type: :string}]})

    case Phantom.Session.elicit(session, elicit, await: true) do
      :not_supported -> {:reply, Tool.text("Hello stranger"), session}
      {:ok, _response} -> {:reply, Tool.text("Hello you"), session}
    end
  end

  def connect(session, _conn), do: {:ok, Phantom.Session.assign(session, user: "alice")}
end

defmodule Phantom.A2A.CallToolTest.Assistant do
  use Phantom.A2A.Agent, name: "Assistant", description: "Answers with the echo tool"

  alias Phantom.A2A.{Message, Part}

  def handle_message(%Message{parts: [%Part{text: text}]}, ctx) do
    {:ok, %{content: [%{text: reply}]}} = Phantom.Router.call_tool(ctx.session, :echo, text: text)
    {:reply, Message.agent(reply), ctx}
  end
end

defmodule Phantom.A2A.CallToolTest do
  use ExUnit.Case, async: true

  alias Phantom.A2A.CallToolTest.Router

  setup do
    session = Phantom.Session.new(nil, router: Router, assigns: %{user: "alice"})
    {:ok, session: session}
  end

  test "calls a tool and returns its result", %{session: session} do
    assert {:ok, %{content: [%{type: :text, text: "alice: hi"}]}} =
             Phantom.Router.call_tool(session, :echo, %{text: "hi"})
  end

  test "waits for a tool that answers from another process", %{session: session} do
    assert {:ok, %{content: [%{text: "later: hi"}]}} =
             Phantom.Router.call_tool(session, "async_echo", %{"text" => "hi"})
  end

  test "validates arguments and the allow-list", %{session: session} do
    assert {:error, %{code: -32602}} = Phantom.Router.call_tool(session, :echo, %{})

    session = Phantom.Session.allow_tools(session, ["async_echo"])
    assert {:error, %{code: _}} = Phantom.Router.call_tool(session, :echo, %{text: "hi"})
  end

  test "there is no client to elicit from", %{session: session} do
    assert {:ok, %{content: [%{text: "Hello stranger"}]}} =
             Phantom.Router.call_tool(session, :ask_name)
  end

  test "an A2A agent can answer with its router's tools" do
    assert {:message, %{"parts" => [%{"text" => "alice: hello"}]}} =
             Phantom.A2A.Test.send_message(Router, "assistant", "hello")
  end
end

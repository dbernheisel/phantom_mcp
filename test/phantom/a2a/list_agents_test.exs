defmodule Phantom.A2A.ListAgentsTest.Agent do
  use Phantom.A2A.Agent, name: "Listed", description: "Listed agent"

  def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Message.agent("ok"), ctx}
  def resolve(_params, _session), do: {:error, :not_found}
end

defmodule Phantom.A2A.ListAgentsTest.DefaultRouter do
  use Phantom.Router, name: "Default"

  agent "research", Phantom.A2A.ListAgentsTest.Agent
  agent "teams/billing", Phantom.A2A.ListAgentsTest.Agent
  agent ":org/:key", Phantom.A2A.ListAgentsTest.Agent, :resolve
end

defmodule Phantom.A2A.ListAgentsTest.CustomRouter do
  use Phantom.Router, name: "Custom"

  agent "research", Phantom.A2A.ListAgentsTest.Agent
  agent ":org/:key", Phantom.A2A.ListAgentsTest.Agent, :resolve

  def list_agents(nil, session),
    do: {:ok, ["research", "#{session.assigns.org}/triage"], "page-2"}

  def list_agents("page-2", session), do: {:ok, ["#{session.assigns.org}/bench"], nil}
end

defmodule Phantom.A2A.ListAgentsTest do
  use ExUnit.Case, async: true

  import Phantom.A2A.Test

  alias Phantom.A2A.ListAgentsTest.{CustomRouter, DefaultRouter}

  test "lists the agent routes without path params by default" do
    assert {:ok, ["research", "teams/billing"], nil} = list_agents(DefaultRouter)
  end

  test "the default respects allow_agents/2" do
    assert {:ok, ["teams/billing"], nil} =
             list_agents(DefaultRouter, allowed_agents: ["teams/billing"])
  end

  test "a router lists the agents it resolves, a page at a time" do
    assert {:ok, ["research", "acme/triage"], "page-2"} =
             list_agents(CustomRouter, assigns: %{org: "acme"})

    assert {:ok, ["acme/bench"], nil} =
             list_agents(CustomRouter, assigns: %{org: "acme"}, cursor: "page-2")
  end
end

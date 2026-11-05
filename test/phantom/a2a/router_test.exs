defmodule Phantom.A2A.RouterTest do
  use ExUnit.Case, async: true

  alias Phantom.A2A.TaskRef

  test "agent paths are plain segments or path params" do
    for path <- ["", "a//b", ":Org/agent", "a b", "research/agent-card.json"] do
      assert_raise ArgumentError, ~r/invalid agent path/, fn ->
        Phantom.Router.agent_route(path, __MODULE__, [])
      end
    end

    assert %{id: "teams/a.b-c_d~e", params?: false, opts: [x: 1]} =
             Phantom.Router.agent_route("teams/a.b-c_d~e", __MODULE__, x: 1)
  end

  test "skills need a description" do
    assert_raise ArgumentError, ~r/needs a description/, fn ->
      Phantom.A2A.AgentSkill.build(:review, tags: [])
    end
  end

  test "task refs round-trip through a string" do
    ref = %TaskRef{
      pubsub: Phantom.A2A.RouterTest.PubSub,
      router: __MODULE__,
      agent_id: "a/b",
      task_id: "t1"
    }

    assert {:ok, ^ref} = ref |> TaskRef.encode() |> TaskRef.decode()

    assert {:error, :invalid} =
             TaskRef.decode(~s(["Elixir.NoSuchAtomAnywhere123", "x", "a", "t"]))

    assert {:error, :invalid} = TaskRef.decode("nope")
  end
end

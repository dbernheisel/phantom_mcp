defmodule Phantom.A2A.EventsTest do
  use ExUnit.Case, async: true

  alias Phantom.A2A.{Artifact, Events, Message, Part, Task, TaskStatus}

  setup do
    task = %Task{id: "t1", context_id: "c", status: %TaskStatus{state: :submitted}}
    {:ok, task: task}
  end

  test "a status update replaces the status", %{task: task} do
    assert {:ok, %Task{status: %TaskStatus{state: :working}}} =
             Events.apply(task, Task.status(:working))
  end

  test "a task replaces the whole task", %{task: task} do
    replacement = %{task | status: %TaskStatus{state: :completed}, metadata: %{"a" => 1}}
    assert {:ok, ^replacement} = Events.apply(task, replacement)
  end

  test "an artifact update adds, replaces, or appends", %{task: task} do
    {:ok, task} = Events.apply(task, Artifact.update("a", [Part.text("one")]))
    {:ok, task} = Events.apply(task, Artifact.update("b", [Part.text("x")]))
    assert [%Artifact{artifact_id: "a"}, %Artifact{artifact_id: "b"}] = task.artifacts

    {:ok, task} = Events.apply(task, Artifact.update("a", [Part.text("two")], append: true))
    assert [%Artifact{parts: [%Part{text: "one"}, %Part{text: "two"}]}, _] = task.artifacts

    {:ok, task} = Events.apply(task, Artifact.update("a", [Part.text("new")]))
    assert [%Artifact{parts: [%Part{text: "new"}]}, _] = task.artifacts
  end

  test "appending to an unknown artifact is an invalid agent response", %{task: task} do
    assert {:error, :unknown_artifact} =
             Events.apply(task, Artifact.update("nope", [Part.text("x")], append: true))
  end

  test "a message leaves the task unchanged", %{task: task} do
    assert {:ok, ^task} = Events.apply(task, Message.agent("hi"))
  end

  test "terminal and interrupted states" do
    for state <- [:completed, :failed, :canceled, :rejected], do: assert(Events.terminal?(state))

    for state <- [:submitted, :working, :input_required, :auth_required],
        do: refute(Events.terminal?(state))

    assert Events.interrupted?(:input_required)
    assert Events.interrupted?(:auth_required)
    refute Events.interrupted?(:working)
  end
end

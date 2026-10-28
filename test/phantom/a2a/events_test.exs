defmodule Phantom.A2A.EventsTest do
  use ExUnit.Case, async: true

  alias Phantom.A2A.{
    Artifact,
    ArtifactUpdate,
    Events,
    Message,
    Part,
    StatusUpdate,
    Task,
    TaskStatus
  }

  setup do
    task = %Task{id: "t1", context_id: "c", status: %TaskStatus{state: :submitted}}
    {:ok, task: task}
  end

  test "a status update replaces the status", %{task: task} do
    assert {:ok, %Task{status: %TaskStatus{state: :working}}, %StatusUpdate{}} =
             Events.apply(task, Task.status(:working))
  end

  test "a task replaces the whole task", %{task: task} do
    replacement = %{task | status: %TaskStatus{state: :completed}, metadata: %{"a" => 1}}

    assert {:ok,
            %Task{status: %TaskStatus{state: :completed}, metadata: %{"a" => 1}, sequence: 1},
            %Task{sequence: 1}} = Events.apply(task, replacement)
  end

  test "an artifact update adds, replaces, or appends", %{task: task} do
    {:ok, task, _} = Events.apply(task, Artifact.update("a", [Part.text("one")]))
    {:ok, task, _} = Events.apply(task, Artifact.update("b", [Part.text("x")]))
    assert [%Artifact{artifact_id: "a"}, %Artifact{artifact_id: "b"}] = task.artifacts

    {:ok, task, _} = Events.apply(task, Artifact.update("a", [Part.text("two")], append: true))
    assert [%Artifact{parts: [%Part{text: "one"}, %Part{text: "two"}]}, _] = task.artifacts

    {:ok, task, _} = Events.apply(task, Artifact.update("a", [Part.text("new")]))
    assert [%Artifact{parts: [%Part{text: "new"}]}, _] = task.artifacts
  end

  test "appending to an unknown artifact is an invalid agent response", %{task: task} do
    assert {:error, :unknown_artifact} =
             Events.apply(task, Artifact.update("nope", [Part.text("x")], append: true))
  end

  test "a message leaves the task unchanged", %{task: task} do
    message = Message.agent("hi")
    assert {:ok, ^task, ^message} = Events.apply(task, message)
  end

  test "numbers each event after the task's last one", %{task: task} do
    {:ok, task, %StatusUpdate{sequence: 1}} = Events.apply(task, Task.status(:working))

    {:ok, task, %ArtifactUpdate{sequence: 2}} =
      Events.apply(task, Artifact.update("a", [Part.text("x")]))

    assert task.sequence == 2
  end

  test "keeps the number of an event that has one", %{task: task} do
    event = %{Task.status(:working) | sequence: 7}
    assert {:ok, %Task{sequence: 7}, %StatusUpdate{sequence: 7}} = Events.apply(task, event)
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

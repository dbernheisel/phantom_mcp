defmodule Phantom.A2A.Events do
  @moduledoc """
  How A2A events change a task.

  Save each event with `apply/2` before you publish it:

      {:ok, task, event} = Phantom.A2A.Events.apply(stored_task, event)
      MyApp.A2ATasks.save!(task)
      Phantom.A2A.publish(task_ref, event)

  `apply/2` numbers the event after the task's last one, and the task keeps
  that number in `sequence`. A client that subscribes while you publish gets
  the task from `c:Phantom.A2A.Agent.get_task/2`, so Phantom skips the events
  already in it. Apply events within the lock or transaction you save the task
  in, so two writers don't number events the same.
  """

  alias Phantom.A2A.{Artifact, ArtifactUpdate, Message, StatusUpdate, Task}

  @terminal ~w[completed failed canceled rejected]a
  @interrupted ~w[input_required auth_required]a

  @type event :: Task.t() | StatusUpdate.t() | ArtifactUpdate.t() | Message.t()

  @doc """
  Apply an event to a task, and return the task with the numbered event.

  An event that already has a `sequence` keeps it. Messages don't change the
  task and aren't numbered. Returns `{:error, :unknown_artifact}` for an append
  to an artifact the task doesn't have.
  """
  @spec apply(Task.t(), event()) :: {:ok, Task.t(), event()} | {:error, :unknown_artifact}
  def apply(%Task{} = task, %Message{} = message), do: {:ok, task, message}

  def apply(%Task{} = task, event) do
    sequence = sequence(event) || task.sequence + 1
    event = put_sequence(event, sequence)

    with {:ok, task} <- change(task, event), do: {:ok, %{task | sequence: sequence}, event}
  end

  @doc "Whether the task already includes a numbered event"
  def seen?(%Task{sequence: last}, event) do
    case sequence(event) do
      nil -> false
      sequence -> sequence <= last
    end
  end

  defp sequence(%Message{}), do: nil
  defp sequence(%Task{sequence: 0}), do: nil
  defp sequence(%{sequence: sequence}), do: sequence

  defp put_sequence(event, sequence), do: %{event | sequence: sequence}

  defp change(%Task{}, %Task{} = task), do: {:ok, task}
  defp change(%Task{} = task, %StatusUpdate{status: status}), do: {:ok, %{task | status: status}}

  defp change(%Task{} = task, %ArtifactUpdate{artifact: artifact, append: true}) do
    case Enum.find_index(task.artifacts, &(&1.artifact_id == artifact.artifact_id)) do
      nil ->
        {:error, :unknown_artifact}

      index ->
        artifacts =
          List.update_at(task.artifacts, index, fn %Artifact{} = existing ->
            %{
              existing
              | parts: existing.parts ++ artifact.parts,
                metadata: merge_metadata(existing.metadata, artifact.metadata)
            }
          end)

        {:ok, %{task | artifacts: artifacts}}
    end
  end

  defp change(%Task{} = task, %ArtifactUpdate{artifact: artifact}) do
    case Enum.find_index(task.artifacts, &(&1.artifact_id == artifact.artifact_id)) do
      nil -> {:ok, %{task | artifacts: task.artifacts ++ [artifact]}}
      index -> {:ok, %{task | artifacts: List.replace_at(task.artifacts, index, artifact)}}
    end
  end

  defp merge_metadata(existing, nil), do: existing
  defp merge_metadata(nil, new), do: new
  defp merge_metadata(existing, new), do: Map.merge(existing, new)

  @doc "Whether a task in this state is finished"
  def terminal?(state), do: state in @terminal

  @doc "Whether a task in this state waits on the client"
  def interrupted?(state), do: state in @interrupted
end

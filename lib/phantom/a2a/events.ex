defmodule Phantom.A2A.Events do
  @moduledoc """
  How A2A events change a task.

  Phantom uses these rules to answer a blocking `SendMessage`. Agents that
  store A2A-shaped tasks can use `apply/2` to save them the same way.
  """

  alias Phantom.A2A.{Artifact, ArtifactUpdate, Message, StatusUpdate, Task}

  @terminal ~w[completed failed canceled rejected]a
  @interrupted ~w[input_required auth_required]a

  @doc """
  Apply an event to a task.

  Returns `{:error, :unknown_artifact}` for an append to an artifact the task
  doesn't have.
  """
  @spec apply(Task.t(), Task.t() | StatusUpdate.t() | ArtifactUpdate.t() | Message.t()) ::
          {:ok, Task.t()} | {:error, :unknown_artifact}
  def apply(%Task{}, %Task{} = task), do: {:ok, task}
  def apply(%Task{} = task, %StatusUpdate{status: status}), do: {:ok, %{task | status: status}}
  def apply(%Task{} = task, %Message{}), do: {:ok, task}

  def apply(%Task{} = task, %ArtifactUpdate{artifact: artifact, append: true}) do
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

  def apply(%Task{} = task, %ArtifactUpdate{artifact: artifact}) do
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

defmodule Phantom.A2A.ArtifactUpdate do
  @moduledoc """
  An event that adds or extends a task's artifact. Build one with
  `Phantom.A2A.Artifact.update/3` and send it with `Phantom.A2A.publish/2`.
  """

  import Phantom.Utils, only: [remove_nils: 1]

  alias Phantom.A2A.Artifact

  @enforce_keys [:artifact]
  defstruct [
    :task_id,
    :context_id,
    :artifact,
    :metadata,
    :sequence,
    append: false,
    last_chunk: false
  ]

  @type t :: %__MODULE__{
          task_id: String.t() | nil,
          context_id: String.t() | nil,
          artifact: Artifact.t(),
          metadata: map() | nil,
          sequence: pos_integer() | nil,
          append: boolean(),
          last_chunk: boolean()
        }

  @doc false
  def from_json(%{"artifact" => artifact} = json) do
    with {:ok, artifact} <- Artifact.from_json(artifact) do
      {:ok,
       %__MODULE__{
         task_id: json["taskId"],
         context_id: json["contextId"],
         artifact: artifact,
         metadata: json["metadata"],
         append: json["append"] == true,
         last_chunk: json["lastChunk"] == true
       }}
    end
  end

  def from_json(_json), do: {:error, "artifact update needs an artifact"}

  @doc false
  def to_json(%__MODULE__{} = update) do
    remove_nils(%{
      "taskId" => update.task_id,
      "contextId" => update.context_id,
      "artifact" => Artifact.to_json(update.artifact),
      "append" => update.append,
      "lastChunk" => update.last_chunk,
      "metadata" => update.metadata
    })
  end
end

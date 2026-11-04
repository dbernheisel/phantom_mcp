defmodule Phantom.A2A.Artifact do
  @moduledoc """
  Output an A2A task produces, such as a report or a file.

  Send artifacts while a task runs with `update/3` and `Phantom.A2A.publish/2`,
  or include them in the `Phantom.A2A.Task` the agent returns.
  """

  import Phantom.Utils, only: [remove_nils: 1]

  alias Phantom.A2A.{ArtifactUpdate, Part}

  @enforce_keys [:artifact_id]
  defstruct [:artifact_id, :name, :description, :metadata, parts: [], extensions: []]

  @type t :: %__MODULE__{
          artifact_id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          metadata: map() | nil,
          parts: [Part.t()],
          extensions: [String.t()]
        }

  @doc """
  An artifact with the given ID and parts. `opts` sets `:name`,
  `:description`, `:metadata`, or `:extensions`.
  """
  def new(artifact_id, parts, opts \\ []) when is_binary(artifact_id) and is_list(parts) do
    struct!(__MODULE__, [artifact_id: artifact_id, parts: parts] ++ opts)
  end

  @doc """
  An event that adds or extends an artifact.

  With `append: true`, the parts are added to the artifact already sent with
  this ID. Otherwise the artifact is added, or replaces one with the same ID.

  ## Options

    * `:append` - add the parts to an existing artifact (default `false`)
    * `:last_chunk` - this is the artifact's final chunk (default `false`)
    * any `new/3` option
  """
  def update(artifact_id, parts, opts \\ []) do
    {update_opts, artifact_opts} = Keyword.split(opts, [:append, :last_chunk, :metadata])

    %ArtifactUpdate{
      artifact: new(artifact_id, parts, artifact_opts),
      append: Keyword.get(update_opts, :append, false),
      last_chunk: Keyword.get(update_opts, :last_chunk, false),
      metadata: update_opts[:metadata]
    }
  end

  @doc false
  def from_json(%{"artifactId" => id, "parts" => [_ | _] = parts} = json) when is_binary(id) do
    with {:ok, parts} <- Part.list_from_json(parts) do
      {:ok,
       %__MODULE__{
         artifact_id: id,
         name: json["name"],
         description: json["description"],
         metadata: json["metadata"],
         parts: parts,
         extensions: json["extensions"] || []
       }}
    end
  end

  def from_json(_json), do: {:error, "artifact needs an artifactId and parts"}

  @doc false
  def to_json(%__MODULE__{} = artifact) do
    remove_nils(%{
      "artifactId" => artifact.artifact_id,
      "name" => artifact.name,
      "description" => artifact.description,
      "metadata" => artifact.metadata,
      "parts" => Enum.map(artifact.parts, &Part.to_json/1),
      "extensions" => if(artifact.extensions != [], do: artifact.extensions)
    })
  end
end

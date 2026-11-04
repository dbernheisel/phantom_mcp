defmodule Phantom.A2A.AgentSkill do
  @moduledoc """
  Something an A2A agent can do, listed on its card. Declare skills with the
  `skill` macro in a `Phantom.A2A.Agent`.
  """

  import Phantom.Utils, only: [remove_nils: 1]

  @enforce_keys [:id, :name, :description]
  defstruct [:id, :name, :description, :input_modes, :output_modes, tags: [], examples: []]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          input_modes: [String.t()] | nil,
          output_modes: [String.t()] | nil,
          tags: [String.t()],
          examples: [String.t()]
        }

  @doc false
  def build(id, attrs) do
    id = to_string(id)
    attrs = Map.new(attrs)

    if not is_binary(attrs[:description]) do
      raise ArgumentError,
            "skill #{inspect(id)} needs a description, from @description or the :description option"
    end

    %__MODULE__{
      id: id,
      name: attrs[:name] || id |> String.replace("_", " ") |> String.capitalize(),
      description: String.trim(attrs.description),
      tags: Map.get(attrs, :tags, []),
      examples: Map.get(attrs, :examples, []),
      input_modes: attrs[:input_modes],
      output_modes: attrs[:output_modes]
    }
  end

  @doc false
  def from_json(%{"id" => id, "name" => name, "description" => description} = json)
      when is_binary(id) do
    {:ok,
     %__MODULE__{
       id: id,
       name: name,
       description: description,
       tags: json["tags"] || [],
       examples: json["examples"] || [],
       input_modes: json["inputModes"],
       output_modes: json["outputModes"]
     }}
  end

  def from_json(_json), do: {:error, "skill needs an id, a name, and a description"}

  @doc false
  def to_json(%__MODULE__{} = skill) do
    remove_nils(%{
      "id" => skill.id,
      "name" => skill.name,
      "description" => skill.description,
      # The field is required and can't be empty, so an untagged skill has its ID.
      "tags" => if(skill.tags == [], do: [skill.id], else: skill.tags),
      "examples" => if(skill.examples != [], do: skill.examples),
      "inputModes" => skill.input_modes,
      "outputModes" => skill.output_modes
    })
  end
end

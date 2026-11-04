defmodule Phantom.A2A.Card do
  @moduledoc """
  An A2A Agent Card: what an agent is, where to reach it, and what it can do.

  Phantom builds each agent's card from its `Phantom.A2A.Agent` module and the
  router's `:a2a` options, and fills in the URLs from the request.
  """

  import Phantom.Utils, only: [remove_nils: 1]

  alias Phantom.A2A.AgentSkill

  defstruct [
    :name,
    :description,
    :version,
    :provider,
    :documentation_url,
    :icon_url,
    :security_schemes,
    :security_requirements,
    supported_interfaces: [],
    capabilities: %{},
    default_input_modes: [],
    default_output_modes: [],
    skills: [],
    extensions: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          version: String.t(),
          provider: map() | nil,
          documentation_url: String.t() | nil,
          icon_url: String.t() | nil,
          security_schemes: map() | nil,
          security_requirements: [map()] | nil,
          supported_interfaces: [map()],
          capabilities: map(),
          default_input_modes: [String.t()],
          default_output_modes: [String.t()],
          skills: [AgentSkill.t()],
          extensions: [extension()]
        }

  @typedoc "A protocol extension the agent supports"
  @type extension :: %{
          required(:uri) => String.t(),
          optional(:description) => String.t(),
          optional(:required) => boolean(),
          optional(:params) => map()
        }

  @doc false
  def from_json(%{"name" => name} = json) when is_binary(name) do
    capabilities = json["capabilities"] || %{}

    with :ok <- check_shape(json, capabilities),
         {:ok, skills} <-
           Phantom.A2A.Part.list_from_json(json["skills"] || [], &AgentSkill.from_json/1) do
      {:ok,
       %__MODULE__{
         name: name,
         description: json["description"],
         version: json["version"],
         provider: json["provider"],
         documentation_url: json["documentationUrl"],
         icon_url: json["iconUrl"],
         security_schemes: json["securitySchemes"],
         security_requirements: json["securityRequirements"],
         supported_interfaces: json["supportedInterfaces"] || [],
         capabilities: capabilities,
         default_input_modes: json["defaultInputModes"] || [],
         default_output_modes: json["defaultOutputModes"] || [],
         skills: skills,
         extensions: Enum.map(capabilities["extensions"] || [], &extension_from_json/1)
       }}
    end
  end

  def from_json(_json), do: {:error, "agent card needs a name"}

  defp check_shape(json, capabilities) do
    valid? =
      is_list(json["supportedInterfaces"] || []) and is_map(capabilities) and
        is_list(capabilities["extensions"] || []) and
        Enum.all?(capabilities["extensions"] || [], &is_map/1)

    if valid?, do: :ok, else: {:error, "agent card has a field of the wrong type"}
  end

  defp extension_from_json(json) do
    remove_nils(%{
      uri: json["uri"],
      description: json["description"],
      required: if(json["required"], do: true),
      params: json["params"]
    })
  end

  @doc false
  def extension_to_json(extension) do
    remove_nils(%{
      "uri" => extension.uri,
      "description" => extension[:description],
      "required" => if(extension[:required], do: true),
      "params" => extension[:params]
    })
  end

  @doc false
  def to_json(%__MODULE__{} = card) do
    remove_nils(%{
      "name" => card.name,
      "description" => card.description,
      "version" => card.version,
      "provider" => card.provider,
      "documentationUrl" => card.documentation_url,
      "iconUrl" => card.icon_url,
      "securitySchemes" => card.security_schemes,
      "securityRequirements" => card.security_requirements,
      "supportedInterfaces" => card.supported_interfaces,
      "capabilities" => card.capabilities,
      "defaultInputModes" => card.default_input_modes,
      "defaultOutputModes" => card.default_output_modes,
      "skills" => Enum.map(skills(card), &AgentSkill.to_json/1)
    })
  end

  # A card must list a skill, so an agent that declares none offers itself.
  defp skills(%__MODULE__{skills: []} = card) do
    [%AgentSkill{id: "default", name: card.name, description: card.description}]
  end

  defp skills(%__MODULE__{skills: skills}), do: skills
end

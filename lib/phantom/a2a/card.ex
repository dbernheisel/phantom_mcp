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
      "skills" => Enum.map(card.skills, &AgentSkill.to_json/1)
    })
  end
end

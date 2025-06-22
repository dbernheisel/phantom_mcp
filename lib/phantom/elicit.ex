defmodule Phantom.Elicit do
  @moduledoc """
  The Model Context Protocol (MCP) provides a standardized way for
  servers to request additional information from users through the
  client during interactions. This flow allows clients to maintain
  control over user interactions and data sharing while enabling
  servers to gather necessary information dynamically. Servers
  request structured data from users with JSON schemas to validate
  responses.

  > #### Error {: .error}
  >
  > Note: this is not yet tested

  https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation

  ```mermaid
  sequenceDiagram
      participant User
      participant Client
      participant Server

      Note over Server,Client: Server initiates elicitation
      Server->>Client: elicitation/create

      Note over Client,User: Human interaction
      Client->>User: Present elicitation UI
      User-->>Client: Provide requested information

      Note over Server,Client: Complete request
      Client-->>Server: Return user response

      Note over Server: Continue processing with new information
  ```
  """

  @enforce_keys ~w[message requested_schema]a

  defstruct [
    :message,
    :requested_schema
  ]

  @type string_property :: %{
          name: String.t(),
          required: boolean(),
          type: :string,
          title: String.t(),
          description: String.t(),
          min_length: pos_integer(),
          max_length: pos_integer(),
          pattern: String.t() | Regex.t(),
          format: :email | :uri | :date | :datetime
        }

  @type enum_property :: %{
          name: String.t(),
          required: boolean(),
          type: :string,
          title: String.t(),
          description: String.t(),
          enum: [{value :: String.t(), name :: String.t()}]
        }

  @type boolean_property :: %{
          name: String.t(),
          required: boolean(),
          type: :boolean,
          title: String.t(),
          description: String.t(),
          default: boolean()
        }

  @type number_property :: %{
          name: String.t(),
          required: boolean(),
          type: :number | :integer,
          title: String.t(),
          description: String.t(),
          minimum: pos_integer(),
          maximum: pos_integer()
        }

  @type t :: %__MODULE__{
          message: String.t(),
          requested_schema: [
            number_property() | boolean_property() | enum_property() | string_property()
          ]
        }

  @type json :: %{
          message: String.t(),
          requestedSchema: %{
            type: String.t(),
            required: [String.t()],
            properties: %{String.t() => map()}
          }
        }

  @spec build(%{
          message: String.t(),
          requested_schema: [
            number_property() | boolean_property() | enum_property() | string_property()
          ]
        }) :: t
  def build(attrs) do
    %{
      struct!(__MODULE__, attrs)
      | requested_schema: attrs[:requested_schema] |> List.wrap() |> Enum.map(&build_property/1)
    }
  end

  defp build_property(%{type: :string} = attrs) do
    attrs =
      Map.take(
        attrs,
        ~w[name required type title description min_length max_length pattern format]a
      )

    if format = attrs[:format] do
      format in ~w[email uri date date_time]a || raise "Invalid format in string property"
    end

    attrs
  end

  defp build_property(%{enum: enum} = attrs) when is_list(enum) do
    attrs
    |> Map.take(~w[name required type title description enum]a)
    |> Map.put(:type, :string)
  end

  defp build_property(%{type: :boolean} = attrs) do
    Map.take(
      attrs,
      ~w[name required type title description default]a
    )
  end

  @integer ~w[integer number]a
  defp build_property(%{type: type} = attrs) when type in @integer do
    Map.take(
      attrs,
      ~w[name required type title description minimum maximum]a
    )
  end

  def to_json(%__MODULE__{} = elicit) do
    %{
      message: elicit.message,
      requestedSchema: %{
        type: "object",
        required:
          Enum.reduce(elicit.requested_schema, [], fn property, acc ->
            if property.required, do: [property.name | acc], else: acc
          end),
        properties:
          Enum.reduce(elicit.requested_schema, %{}, fn property, acc ->
            property = Map.drop(property, [:required])
            {name, attrs} = Map.pop(property, :name)

            Map.put(
              acc,
              name,
              Enum.reduce(attrs, %{}, fn
                {:min_length, v}, acc ->
                  Map.put(acc, :minLength, v)

                {:max_length, v}, acc ->
                  Map.put(acc, :maxLength, v)

                {:pattern, %Regex{} = v}, acc ->
                  Map.put(acc, :pattern, Regex.source(v))

                {:format, :date_time}, acc ->
                  Map.put(acc, :format, "date-time")

                {:enum, v}, acc ->
                  acc
                  |> Map.put(:enum, Enum.map(v, &elem(&1, 0)))
                  |> Map.put(:enumNames, Enum.map(v, &elem(&1, 1)))

                {k, v}, acc ->
                  Map.put(acc, k, v)
              end)
            )
          end)
      }
    }
  end
end

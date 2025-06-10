defmodule Phantom.Tool.InputSchema do
  @moduledoc """
  JSON Schema representing the arguments for the tool

  Learn more at   https://json-schema.org/learn/getting-started-step-by-step

  Example:

      %{
        type: "object",
        properties: %{
          productId: %{
            description: "The unique identifier for a product",
            type: "integer"
          },
          productName: %{
            description: "Name of the product",
            type: "string"
          }
        }
      }

  """
  import Phantom.Utils

  @type t :: %__MODULE__{
          required: boolean(),
          type: String.t(),
          properties: map()
        }

  @type json :: %{
          required(:required) => boolean(),
          required(:type) => String.t(),
          required(:properties) => map()
        }

  defstruct required: [], type: "object", properties: %{}

  def build(nil), do: nil
  def build(attrs), do: struct!(__MODULE__, attrs)

  def to_json(nil), do: %{required: [], type: "object", properties: %{}}

  def to_json(%__MODULE__{} = input_schema) do
    remove_nils(%{
      required: input_schema.required,
      type: input_schema.type,
      properties: input_schema.properties
    })
  end
end

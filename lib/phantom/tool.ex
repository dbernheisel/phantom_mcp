defmodule Phantom.Tool do
  @moduledoc """
  The Model Context Protocol (MCP) allows servers to expose tools
  that can be invoked by language models. Tools enable models to
  interact with external systems, such as querying databases,
  calling APIs, or performing computations. Each tool is uniquely
  identified by a name and includes metadata describing its schema.

  https://modelcontextprotocol.io/specification/2025-03-26/server/tools
  """

  import Phantom.Utils

  alias Phantom.Tool.Annotation
  alias Phantom.Tool.InputSchema

  defstruct [:name, :description, :handler, :function, :input_schema, :annotations]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          handler: module(),
          function: atom(),
          input_schema: InputSchema.t(),
          annotations: Annotation.t()
        }

  @type json :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:inputSchema) => InputSchema.json(),
          optional(:annotations) => Annotation.json()
        }

  def build(attrs) do
    attrs = Map.new(attrs)

    {annotation_attrs, attrs} =
      Map.split(attrs, ~w[title idempotent destructive read_only open_world]a)

    %{
      struct!(__MODULE__, attrs)
      | annotations: Annotation.build(annotation_attrs),
        input_schema: InputSchema.build(attrs[:input_schema])
    }
  end

  def to_json(%__MODULE__{} = tool) do
    remove_nils(%{
      name: tool.name,
      description: tool.description,
      inputSchema: InputSchema.to_json(tool.input_schema),
      annotations: Annotation.to_json(tool.annotations)
    })
  end
end

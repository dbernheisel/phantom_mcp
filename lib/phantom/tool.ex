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

  @doc "Formats the response from an MCP Router to the MCP specification"
  def response(results) do
    {results, error?} =
      Enum.reduce(List.wrap(results), {[], false}, fn result, {acc, error?} ->
        result =
          Enum.reduce(result, %{}, fn
            {:text, nil}, acc -> Map.put(acc, :text, "")
            {:data, nil}, acc -> Map.put(acc, :data, "")
            {:mime_type, mime_type}, acc -> Map.put(acc, :mimeType, mime_type)
            {key, value}, acc -> Map.put(acc, key, value)
          end)

        {result_error?, result} = Map.pop(result, :error, false)
        {[result | acc], error? || result_error?}
      end)

    results = Enum.reverse(results)
    if error?, do: %{content: results, isError: true}, else: %{content: results}
  end
end

defmodule Phantom.Prompt do
  @moduledoc """
  The Model Context Protocol (MCP) provides a standardized way
  for servers to expose prompt templates to clients. Prompts
  allow servers to provide structured messages and instructions
  for interacting with language models. Clients can discover
  available prompts, retrieve their contents, and provide arguments
  to customize them.

  https://modelcontextprotocol.io/specification/2025-03-26/server/prompts
  """

  import Phantom.Utils
  alias Phantom.Prompt.Argument

  defstruct [:name, :description, :handler, :completion_function, :function, arguments: []]

  @type t :: %__MODULE__{
          name: String.t(),
          handler: module(),
          function: atom(),
          completion_function: atom(),
          description: String.t(),
          arguments: [Argument.t()]
        }

  @type json :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:arguments) => %{
            String.t() => String.t()
          }
        }

  @spec build(map() | Keyword.t()) :: t()
  def build(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.update(:name, to_string(attrs[:function]), &to_string/1)

    struct!(
      __MODULE__,
      Map.put(attrs, :arguments, Enum.map(attrs[:arguments] || [], &Argument.build/1))
    )
  end

  @spec to_json(t()) :: json()
  def to_json(%__MODULE__{} = prompt) do
    remove_nils(%{
      name: prompt.name,
      description: prompt.description,
      arguments: Enum.map(prompt.arguments, &Argument.to_json/1)
    })
  end

  @doc "Formats the response from an MCP Router to the MCP specification"
  def response(results, prompt) do
    messages =
      results
      |> List.wrap()
      |> Enum.map(fn result ->
        result
        |> Enum.reduce(%{content: %{}}, fn
          {:role, role}, acc ->
            Map.put(acc, :role, role || "user")

          {:text, text}, acc ->
            put_in(acc[:content][:text], text || "")

          {:data, data}, acc ->
            put_in(acc[:content][:data], data || "")

          {:resource, data}, acc ->
            acc = put_in(acc[:content][:resource], data || %{})
            put_in(acc[:content][:type], "resource")

          {:mime_type, mime_type}, acc ->
            put_in(acc[:content][:mimeType], mime_type || "")

          {:type, type}, acc ->
            put_in(acc[:content][:type], type || "text")

          {key, value}, acc ->
            Map.put(acc, key, value)
        end)
        |> encode()
      end)

    %{
      description: prompt.description,
      messages: messages
    }
  end
end

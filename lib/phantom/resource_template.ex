defmodule Phantom.ResourceTemplate do
  @moduledoc """
  The Model Context Protocol (MCP) provides a standardized way for
  servers to expose resources to clients. Resources allow servers to
  share data that provides context to language models, such as files,
  database schemas, or application-specific information. Each resource
  is uniquely identified by a URI.

  https://modelcontextprotocol.io/specification/2025-03-26/server/resources
  """

  import Phantom.Utils

  defstruct [
    :name,
    :description,
    :function,
    :completion_function,
    :handler,
    :mime_type,
    :path,
    :router,
    :scheme,
    :size,
    :uri,
    :uri_template
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          function: atom(),
          completion_function: atom(),
          handler: module(),
          mime_type: String.t(),
          path: String.t(),
          router: module(),
          scheme: String.t(),
          size: pos_integer(),
          uri: URI.t(),
          uri_template: String.t()
        }

  @type json :: %{
          required(:uri) => String.t(),
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:size) => pos_integer()
        }

  @spec build(map() | Keyword.t()) :: t()
  def build(attrs) do
    attrs = Map.new(attrs)
    uri_template = "#{attrs.scheme}://#{to_uri_6570(attrs.path)}"
    struct!(__MODULE__, Map.put(attrs, :uri_template, uri_template))
  end

  @spec to_json(t()) :: json()
  def to_json(%__MODULE__{} = resource) do
    remove_nils(%{
      uriTemplate: resource.uri_template,
      name: resource.name,
      size: resource.size,
      description: resource.description,
      mimeType: resource.mime_type
    })
  end

  defp to_uri_6570(str) do
    String.replace(str, ~r/:\w*/, fn ":" <> var -> "{#{var}}" end)
  end

  @doc false
  # TODO: not ready
  def updated(uri), do: %{uri: uri}

  @doc "Formats the response from an MCP Router to the MCP specification"
  def response(results, resource_template, uri) do
    %{
      contents:
        results
        |> List.wrap()
        |> Enum.map(fn result ->
          encode(%{
            blob: result[:blob],
            text: result[:text],
            mimeType: result[:mime_type] || resource_template.mime_type,
            uri: uri
          })
        end)
    }
  end
end

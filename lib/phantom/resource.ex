defmodule Phantom.Resource do
  @moduledoc """
  The Model Context Protocol (MCP) provides a standardized way for
  servers to expose resources to clients. Resources allow servers to
  share data that provides context to language models, such as files,
  database schemas, or application-specific information. Each resource
  is uniquely identified by a URI.

  https://modelcontextprotocol.io/specification/2025-03-26/server/resources
  """

  import Phantom.Utils

  @type response :: %{
          contents: [blob_content() | text_content()]
        }

  @type blob_content :: %{
          required(:blob) => binary(),
          required(:uri) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:name) => String.t(),
          optional(:title) => String.t()
        }

  @type text_content :: %{
          required(:text) => binary(),
          required(:uri) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:name) => String.t(),
          optional(:title) => String.t()
        }

  @type resource_link :: %{
          uri: String.t(),
          name: String.t(),
          description: String.t(),
          mimeType: String.t()
        }

  # TODO: not ready
  @doc false
  def updated(uri), do: %{uri: uri}

  @doc """
  Resource as binary content

  The `:uri` and `:mime_type` will be fetched from the current resource template
  within the scope of the request if not provided, but you will need to provide
  the rest.

  - `blob` - Binary data. This will be base64-encoded by Phantom.
  - `:uri` (required) Unique identifier for the resource
  - `:name` (optional) The name of the resource.
  - `:title` (optional) human-readable name of the resource for display purposes.
  - `:description` (optional) Description
  - `:mime_type` (optional) MIME type
  - `:size` (optional) Size in bytes

  For example:

      Phantom.Resource.blob(
        File.read!("foo.png"),
        uri: "test://my-foos/123",
        mime_type: "image/png"
      )
  """
  @spec blob(binary(), Keyword.t() | map()) :: blob_content()
  defmacro blob(binary, attrs \\ []) do
    mime_type =
      get_var(attrs, :mime_type, [:spec, :mime_type], __CALLER__, "application/octet-stream")

    uri = get_var(attrs, :uri, [:params, "uri"], __CALLER__)

    quote bind_quoted: [
            uri: uri,
            mime_type: mime_type,
            binary: binary,
            attrs: Macro.escape(attrs)
          ] do
      remove_nils(%{
        blob: Base.encode64(binary),
        uri: uri,
        mimeType: mime_type,
        name: attrs[:name],
        title: attrs[:title],
        size: attrs[:size]
      })
    end
  end

  @doc """
  Resource as text content

  The `:uri` and `:mime_type` will be fetched from the current resource template
  within the scope of the request if not provided, but you will need to provide
  the rest.

  - `text` - Text data. If a map, then it will be encoded into JSON and `:mime_type` will be set accordingly unless provided.
  - `:uri` (required) Unique identifier for the resource
  - `:name` (optional) The name of the resource.
  - `:title` (optional) human-readable name of the resource for display purposes.
  - `:description` (optional) Description
  - `:mime_type` (optional) MIME type. Defaults to `"text/plain"`
  - `:size` (optional) Size in bytes

  For example:

      Phantom.ResourceTemplate.text(
        "## Why hello there",
        uri: "test://obi-wan-quotes/hello-there",
        mime_type: "text/markdown"
      )

      Phantom.ResourceTemplate.text(
        %{why: "hello there"},
        uri: "test://my-foos/json",
        # mime_type: "application/json"  # set by Phantom
      )
  """
  @spec text(String.t() | map, Keyword.t() | map()) :: text_content()
  defmacro text(text, attrs \\ %{}) do
    mime_type = get_var(attrs, :mime_type, [:spec, :mime_type], __CALLER__, "text/plain")
    uri = get_var(attrs, :uri, [:params, "uri"], __CALLER__)

    quote bind_quoted: [
            text: text,
            uri: uri,
            mime_type: mime_type,
            attrs: Macro.escape(attrs)
          ] do
      tmp_text = if is_map(t = text), do: JSON.encode!(t), else: t
      json_mime = if is_map(text), do: "application/json"

      remove_nils(%{
        text: tmp_text,
        uri: uri,
        mimeType: json_mime || mime_type || "text/plain",
        name: attrs[:name],
        title: attrs[:title],
        size: attrs[:size]
      })
    end
  end

  @doc "Formats the response from an MCP Router to the MCP specification"
  def response(%{contents: _} = results), do: results

  def response(results) do
    %{contents: List.wrap(results)}
  end

  @type list_response :: %{nextCursor: String.t() | nil, resources: [resource_link()]}
  @spec list([resource_link()], cursor :: String.t() | nil) :: list_response()
  @doc "Formats the response from the MCP Router to the MCP specification for listing resources"
  def list(resource_links, next_cursor) do
    %{resources: List.wrap(resource_links), nextCursor: next_cursor}
  end

  @doc """
  Formats a resource_template and the provided attributes as a resource link. This is
  typicaly used when listing resources or when tools embed a resource_link within its result.
  """
  @spec resource_link(string_uri :: String.t(), Phantom.ResourceTemplate.t(), map()) ::
          resource_link()
  def resource_link(uri, %Phantom.ResourceTemplate{} = resource_template, attrs \\ %{}) do
    remove_nils(%{
      uri: uri,
      mimeType: attrs[:mime_type] || resource_template.mime_type,
      description: attrs[:description] || resource_template.description,
      name: attrs[:name]
    })
  end
end

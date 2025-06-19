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
  alias Phantom.Tool.JSONSchema

  @enforce_keys ~w[name handler function]a
  defstruct [
    :name,
    :description,
    :mime_type,
    :handler,
    :function,
    :output_schema,
    :input_schema,
    :annotations,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          handler: module(),
          function: atom(),
          mime_type: String.t(),
          meta: map(),
          input_schema: JSONSchema.t(),
          output_schema: JSONSchema.t(),
          annotations: Annotation.t()
        }

  @type json :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:inputSchema) => InputSchema.json(),
          optional(:outputSchema) => OutputSchema.json(),
          optional(:annotations) => Annotation.json()
        }

  @type image_response :: %{
          content: [
            type: :image,
            data: base64_binary :: binary(),
            mimeType: String.t()
          ]
        }

  @type audio_response :: %{
          content: [
            type: :audio,
            data: base64_binary :: binary(),
            mimeType: String.t()
          ]
        }

  @type embedded_text_resource :: %{
          required(:uri) => String.t(),
          required(:text) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:title) => String.t(),
          optional(:description) => String.t()
        }
  @type embedded_blob_resource :: %{
          required(:uri) => String.t(),
          required(:data) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:title) => String.t(),
          optional(:description) => String.t()
        }

  @type embedded_resource_response :: %{
          content: [
            type: :resource,
            resource:
              embedded_text_resource()
              | embedded_blob_resource()
          ]
        }

  @type resource_link_response :: %{
          content: [
            type: :resource_link,
            uri: String.t(),
            name: String.t(),
            description: String.t(),
            mimeType: String.t()
          ]
        }

  @type text_response :: %{
          content: [
            type: :text,
            text: String.t()
          ]
        }

  @type structured_response :: %{
          structuredContent: map(),
          content: [
            type: :text,
            text: json_encoded :: String.t()
          ]
        }

  @type error_response :: %{
          isError: true,
          content: [
            type: :text,
            text: String.t()
          ]
        }

  @type response ::
          image_response()
          | audio_response()
          | text_response()
          | structured_response()
          | embedded_resource_response()
          | resource_link_response()

  def build(attrs) do
    attrs = Map.new(attrs)

    {annotation_attrs, attrs} =
      Map.split(attrs, ~w[title idempotent destructive read_only open_world]a)

    %{
      struct!(__MODULE__, attrs)
      | annotations: Annotation.build(annotation_attrs),
        output_schema: JSONSchema.build(attrs[:output_schema]),
        input_schema: JSONSchema.build(attrs[:input_schema])
    }
  end

  def to_json(%__MODULE__{} = tool) do
    remove_nils(%{
      name: tool.name,
      description: tool.description,
      inputSchema: JSONSchema.to_json(tool.input_schema),
      outputSchema: if(tool.output_schema, do: JSONSchema.to_json(tool.output_schema)),
      annotations: Annotation.to_json(tool.annotations)
    })
  end

  @spec text(map) :: structured_response()
  def text(data) when is_map(data) do
    %{
      structuredContent: data,
      content: [%{type: "text", text: JSON.encode!(data)}]
    }
  end

  @spec text(String.t()) :: text_response()
  def text(data) do
    %{content: [%{type: "text", text: data || ""}]}
  end

  @spec error(message :: String.t()) :: error_response()
  def error(message) do
    %{content: [%{type: "text", text: message}], isError: true}
  end

  @spec audio(binary()) :: audio_response()
  defmacro audio(data, attrs \\ []) do
    mime_type =
      get_var(
        attrs,
        :mime_type,
        [:spec, :mime_type],
        __CALLER__,
        "application/octet-stream"
      )

    quote do
      %{
        content: [
          %{
            type: "audio",
            data: Base.encode64(unquote(data) || <<>>),
            mimeType: unquote(mime_type)
          }
        ]
      }
    end
  end

  @spec image(binary()) :: image_response()
  defmacro image(data, attrs \\ []) do
    mime_type =
      get_var(
        attrs,
        :mime_type,
        [:spec, :mime_type],
        __CALLER__,
        "application/octet-stream"
      )

    quote do
      %{
        content: [
          %{
            type: "image",
            data: Base.encode64(unquote(data) || <<>>),
            mimeType: unquote(mime_type)
          }
        ]
      }
    end
  end

  @spec embedded_resource(string_uri :: String.t(), map()) :: embedded_resource_response()
  @doc """
  Embedded resource reponse.
  """
  def embedded_resource(uri, resource) do
    %{
      content: [%{type: :resource, resource: Map.put(resource, :uri, uri)}]
    }
  end

  @doc """
  Resource link reponse.
  """
  @spec resource_link(string_uri :: String.t(), Phantom.ResourceTemplate.t(), map()) ::
          resource_link_response()
  def resource_link(uri, resource_template, resource \\ %{}) do
    resource = Map.new(resource)
    resource_link = Phantom.Resource.resource_link(uri, resource_template, resource)

    %{
      content: [
        remove_nils(Map.put(resource_link, :type, :resource_link))
      ]
    }
  end
end

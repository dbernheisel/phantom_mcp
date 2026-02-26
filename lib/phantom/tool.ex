defmodule Phantom.Tool do
  @moduledoc """
  The Model Context Protocol (MCP) allows servers to expose tools
  that can be invoked by language models. Tools enable models to
  interact with external systems, such as querying databases,
  calling APIs, or performing computations. Each tool is uniquely
  identified by a name and includes metadata describing its schema.

  https://modelcontextprotocol.io/specification/2025-03-26/server/tools

  ```mermaid
  sequenceDiagram
      participant LLM
      participant Client
      participant Server

      Note over Client,Server: Discovery
      Client->>Server: tools/list
      Server-->>Client: List of tools

      Note over Client,LLM: Tool Selection
      LLM->>Client: Select tool to use

      Note over Client,Server: Invocation
      Client->>Server: tools/call
      Server-->>Client: Tool result
      Client->>LLM: Process result

      Note over Client,Server: Updates
      Server--)Client: tools/list_changed
      Client->>Server: tools/list
      Server-->>Client: Updated tools
  ```
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
          input_schema: JSONSchema.t() | nil,
          output_schema: JSONSchema.t() | nil,
          annotations: Annotation.t()
        }

  @type json :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:inputSchema) => JSONSchema.json(),
          optional(:outputSchema) => JSONSchema.json(),
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

  @doc """
  Build a tool spec. Be intentional with the name and description when defining
  the tool since it will inform the LLM when to use the tool.

  The `Phantom.Router.tool/3` macro will build these specs.

  Fields:

  - `:name` - The name of the tool.
  - `:title` A human-readable title for the tool, useful for UI display.
  - `:description` - The description of the tool and when to use it.
  - `:mime_type` - the MIME type of the results.
  - `:handler` - The module to call.
  - `:function` - The function to call on the handler module.
  - `:output_schema` - the JSON schema of the results.
  - `:input_schema` - The JSON schema of the input arguments.
  - `:read_only` If `true`, indicates the tool does not modify its environment.
  - `:destructive` If `true`, the tool may perform destructive updates (only meaningful when `:read_only` is `false`).
  - `:idempotent` If `true`, calling the tool repeatedly with the same arguments has no additional effect (only meaningful when `:read_only` is `false`).
  - `:open_world` If `true`, the tool may interact with an "open world" of external entities.

  """
  def build(attrs) do
    attrs = Map.new(attrs)

    {annotation_attrs, attrs} =
      Map.split(attrs, ~w[title idempotent destructive read_only open_world]a)

    attrs =
      Map.merge(attrs, %{
        name: attrs[:name] || to_string(attrs[:function])
      })

    %{
      struct!(__MODULE__, attrs)
      | annotations: Annotation.build(annotation_attrs),
        input_schema: JSONSchema.build(attrs[:input_schema]),
        output_schema: JSONSchema.build(attrs[:output_schema])
    }
  end

  @doc """
  Represent a Tool spec as json when listing the available tools to clients.
  """
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
  @doc """
  Tool response as audio content

  The `:mime_type` will be fetched from the current tool within the scope of
  the request if not provided, but you will need to provide the rest.

  - `binary` - Binary data.
  - `:mime_type` (optional) MIME type. Defaults to `"application/octet-stream"`

  For example:

      Phantom.Tool.audio(File.read!("game-over.wav"))

      Phantom.Tool.audio(
        File.read!("game-over.wav"),
        mime_type: "audio/wav"
      )
  """
  defmacro audio(binary, attrs \\ []) do
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
            data: Base.encode64(unquote(binary) || <<>>),
            mimeType: unquote(mime_type)
          }
        ]
      }
    end
  end

  @spec image(binary()) :: image_response()
  @doc """
  Tool response as image content

  The `:mime_type` will be fetched from the current tool within the scope of
  the request if not provided, but you will need to provide the rest.

  - `binary` - Binary data.
  - `:mime_type` (optional) MIME type. Defaults to `"application/octet-stream"`

  For example:

      Phantom.Tool.image(File.read!("tower.png"))

      Phantom.Tool.audio(
        File.read!("tower.png"),
        mime_type: "image/png"
      )
  """
  defmacro image(binary, attrs \\ []) do
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
            data: Base.encode64(unquote(binary) || <<>>),
            mimeType: unquote(mime_type)
          }
        ]
      }
    end
  end

  @doc """
  Embedded resource response.

  Typically used with your router's `read_resource/3` function.
  See `Phantom.Router.read_resource/3` for more information
  """
  @spec embedded_resource(string_uri :: String.t(), map()) :: embedded_resource_response()
  def embedded_resource(uri, resource) do
    %{
      content: [%{type: :resource, resource: Map.put(resource, :uri, uri)}]
    }
  end

  @doc """
  Resource link reponse.

  Typically used with your router's `resource_uri/3` function.
  See `Phantom.Router.resource_uri/3` for more information.
  """
  @spec resource_link(string_uri :: String.t(), Phantom.ResourceTemplate.t(), map()) ::
          resource_link_response()
  def resource_link(uri, resource_template, resource_attrs \\ %{}) do
    resource_attrs = Map.new(resource_attrs)
    resource_link = Phantom.Resource.resource_link(uri, resource_template, resource_attrs)

    %{
      content: [
        remove_nils(Map.put(resource_link, :type, :resource_link))
      ]
    }
  end

  @doc "Formats the response from an MCP Router to the MCP specification"
  def response(%{content: _} = results), do: results

  def response(results) do
    %{content: List.wrap(results)}
  end
end

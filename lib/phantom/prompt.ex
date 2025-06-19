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

  @enforce_keys ~w[name handler function]a
  defstruct [
    :name,
    :description,
    :handler,
    :completion_function,
    :function,
    meta: %{},
    arguments: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          handler: module(),
          function: atom(),
          completion_function: atom(),
          description: String.t(),
          meta: map(),
          arguments: [Argument.t()]
        }

  @type json :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:arguments) => %{
            String.t() => String.t()
          }
        }

  @type text_content :: %{
          type: :text,
          data: String.t()
        }

  @type image_content :: %{
          type: :image,
          data: base64_encoded :: String.t(),
          mimeType: String.t()
        }

  @type audio_content :: %{
          type: :audio,
          data: base64_encoded :: String.t(),
          mimeType: String.t()
        }

  @type embedded_resource_content :: %{
          type: :resource,
          resource: Phantom.ResourceTemplate.resource()
        }
  @type message :: %{
          role: :assistant | :user,
          content:
            text_content()
            | image_content()
            | audio_content()
            | embedded_resource_content()
        }

  @type response :: %{
          description: String.t(),
          messages: [message()]
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

  @doc """
  Formats the response from an MCP Router to the MCP specification

  Provide a keyword list of messages with a keyword list. The key
  should contain the role, and the value contain the message.

  For example:

      require Phantom.Prompt, as: Prompt
      Prompt.response([
        assistant: Prompt.audio(File.read!("foo.wav"), "audio/wav"),
        user: Prompt.text("Wow that was interesting"),
        assistant: Prompt.image(File.read!("bar.png"), "image/png"),
        user: Prompt.text("amazing"),
        assistant: Prompt.resource("myapp://foo/123")
      ], prompt)
  """

  defmacro response(messages) when is_list(messages) do
    if not Macro.Env.has_var?(__CALLER__, {:session, nil}) do
      raise "session was not supplied to the response. Phantom requires the variable named `session` to exist, or use response/2."
    end

    quote do
      prompt = var!(session, nil).request.spec
      Phantom.Prompt.response(unquote(messages), prompt)
    end
  end

  def response(messages, prompt) when is_list(messages) do
    %{
      description: prompt.description,
      messages:
        Enum.map(messages, fn {role, content} ->
          %{role: role, content: content}
        end)
    }
  end

  @spec text(String.t()) :: text_content()
  def text(data), do: %{type: "text", text: data || ""}

  @spec audio(binary(), String.t()) :: audio_content()
  def audio(data, mime_type) do
    %{type: "audio", data: Base.encode64(data || <<>>), mimeType: mime_type}
  end

  @spec image(binary(), String.t()) :: image_content()
  def image(data, mime_type) do
    %{type: "image", data: Base.encode64(data || <<>>), mimeType: mime_type}
  end

  @spec embedded_resource(string_uri :: String.t(), map()) :: embedded_resource_content()
  @doc """
  Embedded resource reponse.
  """
  def embedded_resource(uri, resource) do
    %{type: :resource, resource: Map.put(resource, :uri, uri)}
  end
end

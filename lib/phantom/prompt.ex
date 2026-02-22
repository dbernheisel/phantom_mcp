defmodule Phantom.Prompt do
  @moduledoc """
  The Model Context Protocol (MCP) provides a standardized way
  for servers to expose prompt templates to clients. Prompts
  allow servers to provide structured messages and instructions
  for interacting with language models. Clients can discover
  available prompts, retrieve their contents, and provide arguments
  to customize them.

  ```mermaid
  sequenceDiagram
      participant Client
      participant Server

      Note over Client,Server: Discovery
      Client->>Server: prompts/list
      Server-->>Client: List of prompts

      Note over Client,Server: Usage
      Client->>Server: prompts/get
      Server-->>Client: Prompt content

      opt listChanged
        Note over Client,Server: Changes
        Server--)Client: prompts/list_changed
        Client->>Server: prompts/list
        Server-->>Client: Updated prompts
      end
  ```

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
    :icons,
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
          arguments: [Argument.t()],
          icons: [Phantom.Icon.t()] | nil
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
          resource: Phantom.Resource.response()
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
  @doc """
  Build a prompt spec

  The `Phantom.Router.prompt/3` macro will build these specs.

  Fields:
    - `:name` - The name of the prompt.
    - `:description` - The description of the resource and when to use it.
    - `:handler` - The module to call.
    - `:function` - The function to call on the handler module.
    - `:completion_function` - The function to call on the handler module that will provide possible completion results.
    - `:arguments` - A list of arguments that the prompt takes.

  Argument fields:
    - `:name` - the name of the argument, eg: "username"
    - `:description` - description of the argument, eg, "Your Github username"
    - `:required` - whether the argument is required in order to be called, ie: `true` or `false`
  """
  def build(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.update(:name, to_string(attrs[:function]), &to_string/1)

    icons =
      case attrs[:icons] do
        nil -> nil
        icons when is_list(icons) -> Enum.map(icons, &Phantom.Icon.build/1)
      end

    struct!(
      __MODULE__,
      attrs
      |> Map.put(:arguments, Enum.map(attrs[:arguments] || [], &Argument.build/1))
      |> Map.put(:icons, icons)
    )
  end

  @spec to_json(t()) :: json()
  @doc """
  Represent a Prompt spec as json when listing the available prompts to clients.
  """
  def to_json(%__MODULE__{} = prompt) do
    remove_nils(%{
      name: prompt.name,
      description: prompt.description,
      arguments: Enum.map(prompt.arguments, &Argument.to_json/1),
      icons: Phantom.Icon.to_json_list(prompt.icons)
    })
  end

  @doc """
  Formats the response from an MCP Router to the MCP specification

  Provide a keyword list of messages with a keyword list. The key
  should contain the role, and the value contain the message.

  For example:

      require Phantom.Prompt, as: Prompt
      {:ok, uri, resource} = MyApp.MCP.Router.read_resource(session, :my_resource, 123)

      Prompt.response([
        assistant: Prompt.audio(File.read!("foo.wav"), "audio/wav"),
        user: Prompt.text("Wow that was interesting"),
        assistant: Prompt.image(File.read!("bar.png"), "image/png"),
        user: Prompt.text("amazing"),
        assistant: Prompt.embedded_resource(uri, resource)
      ])
  """

  defmacro response(%{messages: _} = response), do: response

  defmacro response(messages) when is_list(messages) do
    if not Macro.Env.has_var?(__CALLER__, {:session, nil}) do
      raise "session was not supplied to the response. Phantom requires the variable named `session` to exist, or use response/2."
    end

    quote do
      prompt = var!(session, nil).request.spec
      Phantom.Prompt.response(unquote(messages), prompt)
    end
  end

  def response(%{messages: _} = response, _prompt), do: response

  @doc """
  Construct a prompt response with the provided messages for the given prompt

  See `response/1` macro version that do the same thing but will fetch the
  prompt spec from the current session.
  """
  @spec response([message()], Phantom.Prompt.t()) :: response()
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
  @doc """
  Build a text message for the prompt
  """
  def text(data), do: %{type: :text, text: data || ""}

  @spec audio(binary(), String.t()) :: audio_content()
  @doc """
  Build an audio message for the prompt

  The provided binary will be base64-encoded.
  """
  def audio(data, mime_type) do
    %{type: :audio, data: Base.encode64(data || <<>>), mimeType: mime_type}
  end

  @spec image(binary(), String.t()) :: image_content()
  @doc """
  Build an image message for the prompt

  The provided binary will be base64-encoded.
  """
  def image(binary, mime_type) do
    %{type: :image, data: Base.encode64(binary || <<>>), mimeType: mime_type}
  end

  @spec embedded_resource(string_uri :: String.t(), map()) :: embedded_resource_content()
  @doc """
  Embedded resource reponse.
  """
  def embedded_resource(uri, resource) do
    %{type: :resource, resource: Map.put(resource, :uri, uri)}
  end
end

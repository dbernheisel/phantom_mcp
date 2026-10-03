defmodule Conformance.MCP.Router do
  @moduledoc """
  Mirrors the reference "everything" server used by the official MCP
  conformance suite (https://github.com/modelcontextprotocol/conformance).

  Only Phantom's public API is used, so failing scenarios point at gaps in
  Phantom rather than in this fixture.
  """

  use Phantom.Router,
    name: "mcp-conformance-test-server",
    vsn: "1.0.0"

  alias Phantom.Session
  require Phantom.Tool, as: Tool
  require Phantom.Prompt, as: Prompt
  require Phantom.Resource, as: Resource
  require Phantom.ClientLogger, as: ClientLogger

  # 1x1 red PNG pixel and a minimal WAV file, identical to the reference server
  @image Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
         )
  @audio Base.decode64!("UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA=")

  def connect(session, _conn), do: {:ok, session}

  ## Tools

  tool :test_simple_text, description: "Tests simple text content response"
  tool :test_image_content, description: "Tests image content response"
  tool :test_audio_content, description: "Tests audio content response"
  tool :test_embedded_resource, description: "Tests embedded resource content response"

  tool :test_multiple_content_types,
    description: "Tests response with multiple content types (text, image, resource)"

  tool :test_tool_with_logging, description: "Tests tool that emits log messages during execution"
  tool :test_tool_with_progress, description: "Tests tool that reports progress notifications"
  tool :test_error_handling, description: "Tests error response handling"

  tool :test_sampling,
    description: "Tests server-initiated sampling (LLM completion request)",
    input_schema: %{
      required: [:prompt],
      properties: %{prompt: %{type: "string", description: "The prompt to send to the LLM"}}
    }

  tool :test_elicitation,
    description: "Tests server-initiated elicitation (user input request)",
    input_schema: %{
      required: [:message],
      properties: %{message: %{type: "string", description: "The message to show the user"}}
    }

  tool :test_elicitation_sep1034_defaults,
    description: "Tests elicitation with default values per SEP-1034"

  tool :test_elicitation_sep1330_enums,
    description: "Tests elicitation with enum schema improvements per SEP-1330"

  # `input_schema` only keeps `type`, `properties`, and `required`, so the
  # reference schema's `$schema`, `$defs`, `allOf`, `if`/`then`/`else`, and
  # `additionalProperties` cannot be expressed.
  tool :json_schema_2020_12_tool,
    description: "Tool with JSON Schema 2020-12 features for conformance testing (SEP-1613)",
    input_schema: %{
      type: "object",
      properties: %{
        name: %{type: "string"},
        address: %{
          type: "object",
          properties: %{street: %{type: "string"}, city: %{type: "string"}}
        },
        contactMethod: %{type: "string", enum: ["phone", "email"]},
        phone: %{type: "string"},
        email: %{type: "string"}
      }
    }

  def test_simple_text(_params, session) do
    {:reply, Tool.text("This is a simple text response for testing."), session}
  end

  def test_image_content(_params, session) do
    {:reply, Tool.image(@image, mime_type: "image/png"), session}
  end

  def test_audio_content(_params, session) do
    {:reply, Tool.audio(@audio, mime_type: "audio/wav"), session}
  end

  def test_embedded_resource(_params, session) do
    {:reply,
     Tool.embedded_resource("test://embedded-resource", %{
       mimeType: "text/plain",
       text: "This is an embedded resource content."
     }), session}
  end

  def test_multiple_content_types(_params, session) do
    resource = %{mimeType: "application/json", text: JSON.encode!(%{test: "data", value: 123})}

    content =
      Tool.text("Multiple content types test:").content ++
        Tool.image(@image, mime_type: "image/png").content ++
        Tool.embedded_resource("test://mixed-content-resource", resource).content

    {:reply, %{content: content}, session}
  end

  # Notifications are cast to the session process, so the work runs in a
  # Task to keep them ordered before the final response.
  def test_tool_with_logging(_params, session) do
    Task.start(fn ->
      for message <- ["Tool execution started", "Tool processing data"] do
        ClientLogger.log(session, :info, message, "conformance-test-server")
        Process.sleep(50)
      end

      ClientLogger.log(session, :info, "Tool execution completed", "conformance-test-server")
      Session.respond(session, Tool.text("Tool with logging executed successfully"))
    end)

    {:noreply, session}
  end

  def test_tool_with_progress(_params, session) do
    token = Session.progress_token(session)

    Task.start(fn ->
      for progress <- [0, 50, 100] do
        Session.notify_progress(session, progress, 100)
        Process.sleep(50)
      end

      Session.respond(session, Tool.text(to_string(token || 0)))
    end)

    {:noreply, session}
  end

  def test_error_handling(_params, session) do
    {:reply, Tool.error("This tool intentionally returns an error for testing"), session}
  end

  # Phantom does not implement server-initiated sampling yet.
  def test_sampling(_params, session) do
    {:reply, Tool.text("Sampling not supported or error: not implemented"), session}
  end

  def test_elicitation(%{"message" => message}, session) do
    elicitation =
      Phantom.Elicit.build(%{
        message: message,
        requested_schema: [
          %{type: :string, name: "response", required: true, description: "User's response"}
        ]
      })

    elicit_reply(session, elicitation, "User response")
  end

  def test_elicitation_sep1034_defaults(_params, session) do
    elicitation =
      Phantom.Elicit.build(%{
        message: "Please review and update the form fields with defaults",
        requested_schema: [
          %{
            type: :string,
            name: "name",
            required: false,
            description: "User name",
            default: "John Doe"
          },
          %{type: :integer, name: "age", required: false, description: "User age", default: 30},
          %{
            type: :number,
            name: "score",
            required: false,
            description: "User score",
            default: 95.5
          },
          %{
            type: :enum,
            name: "status",
            required: false,
            description: "User status",
            enum: ["active", "inactive", "pending"],
            default: "active"
          },
          %{
            type: :boolean,
            name: "verified",
            required: false,
            description: "Verification status",
            default: true
          }
        ]
      })

    elicit_reply(session, elicitation, "Elicitation completed")
  end

  def test_elicitation_sep1330_enums(_params, session) do
    elicitation =
      Phantom.Elicit.build(%{
        message: "Please select options from the enum fields",
        requested_schema: [
          %{
            type: :enum,
            name: "untitledSingle",
            required: false,
            description: "Select one option",
            enum: ["option1", "option2", "option3"]
          },
          %{
            type: :enum,
            name: "titledSingle",
            required: false,
            description: "Select one option with titles",
            enum: [
              {"value1", "First Option"},
              {"value2", "Second Option"},
              {"value3", "Third Option"}
            ]
          },
          # Phantom has no API for the deprecated `enumNames` form; this
          # is the closest equivalent.
          %{
            type: :enum,
            name: "legacyEnum",
            required: false,
            description: "Select one option (legacy)",
            enum: [{"opt1", "Option One"}, {"opt2", "Option Two"}, {"opt3", "Option Three"}]
          },
          %{
            type: :enum,
            name: "untitledMulti",
            required: false,
            description: "Select multiple options",
            multi: true,
            min: 1,
            max: 3,
            enum: ["option1", "option2", "option3"]
          },
          %{
            type: :enum,
            name: "titledMulti",
            required: false,
            description: "Select multiple options with titles",
            multi: true,
            min: 1,
            max: 3,
            enum: [
              {"value1", "First Choice"},
              {"value2", "Second Choice"},
              {"value3", "Third Choice"}
            ]
          }
        ]
      })

    elicit_reply(session, elicitation, "Elicitation completed")
  end

  def json_schema_2020_12_tool(params, session) do
    {:reply, Tool.text("JSON Schema 2020-12 tool called with: #{JSON.encode!(params)}"), session}
  end

  defp elicit_reply(session, elicitation, label) do
    text =
      case Session.elicit(session, elicitation) do
        {:ok, result} ->
          "#{label}: action=#{result["action"]}, content=#{JSON.encode!(result["content"] || %{})}"

        other ->
          "Elicitation not supported or error: #{inspect(other)}"
      end

    {:reply, Tool.text(text), session}
  end

  ## Resources

  # The reference server uses URIs with an authority (`test://static-text`,
  # `test://template/{id}/data`), which `Phantom.Router.resource/4` rejects
  # because it routes on the path only. The closest supported forms are used.
  resource "test:///static-text", :static_text,
    description: "A static text resource for testing",
    mime_type: "text/plain"

  resource "test:///static-binary", :static_binary,
    description: "A static binary resource (image) for testing",
    mime_type: "image/png"

  resource "test:///template/:id/data", :template,
    description: "A resource template with parameter substitution",
    mime_type: "application/json"

  resource "test:///watched-resource", :watched_resource,
    description: "A resource that auto-updates every 3 seconds",
    mime_type: "text/plain"

  def static_text(_params, session) do
    {:reply, Resource.text("This is the content of the static text resource."), session}
  end

  def static_binary(_params, session) do
    {:reply, Resource.blob(@image), session}
  end

  def template(%{"id" => id}, session) do
    {:reply, Resource.text(%{id: id, templateTest: true, data: "Data for ID: #{id}"}), session}
  end

  def watched_resource(_params, session) do
    {:reply, Resource.text("Watched resource content"), session}
  end

  def list_resources(_cursor, session) do
    links =
      for {name, title} <- [
            static_text: "Static Text Resource",
            static_binary: "Static Binary Resource",
            watched_resource: "Watched Resource"
          ] do
        {:ok, uri, spec} = resource_for(session, name, [])
        Resource.resource_link(uri, spec, name: title)
      end

    {:reply, Resource.list(links, nil), session}
  end

  ## Prompts

  prompt :test_simple_prompt, description: "A simple prompt without arguments"

  prompt :test_prompt_with_arguments,
    description: "A prompt with required arguments",
    completion_function: :complete_argument,
    arguments: [
      %{name: "arg1", description: "First test argument", required: true},
      %{name: "arg2", description: "Second test argument", required: true}
    ]

  prompt :test_prompt_with_embedded_resource,
    description: "A prompt that includes an embedded resource",
    arguments: [
      %{name: "resourceUri", description: "URI of the resource to embed", required: true}
    ]

  prompt :test_prompt_with_image, description: "A prompt that includes image content"

  def test_simple_prompt(_params, session) do
    {:reply, Prompt.response(user: Prompt.text("This is a simple prompt for testing.")), session}
  end

  def test_prompt_with_arguments(%{"arg1" => arg1, "arg2" => arg2}, session) do
    {:reply,
     Prompt.response(user: Prompt.text("Prompt with arguments: arg1='#{arg1}', arg2='#{arg2}'")),
     session}
  end

  def test_prompt_with_embedded_resource(%{"resourceUri" => uri}, session) do
    {:reply,
     Prompt.response(
       user:
         Prompt.embedded_resource(uri, %{
           mimeType: "text/plain",
           text: "Embedded resource content for testing."
         }),
       user: Prompt.text("Please process the embedded resource above.")
     ), session}
  end

  def test_prompt_with_image(_params, session) do
    {:reply,
     Prompt.response(
       user: Prompt.image(@image, "image/png"),
       user: Prompt.text("Please analyze the image above.")
     ), session}
  end

  def complete_argument(_argument, _value, session) do
    {:reply, %{values: [], total: 0, has_more: false}, session}
  end
end

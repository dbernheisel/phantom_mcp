defmodule Phantom.Conformance.MCP.Router do
  @moduledoc """
  Mirrors the reference "everything" server used by the official MCP
  conformance suite (https://github.com/modelcontextprotocol/conformance).

  Only Phantom's public API is used, so failing scenarios point at gaps in
  Phantom rather than in this fixture.
  """

  use Phantom.Router,
    name: "mcp-conformance-test-server",
    vsn: "1.0.0",
    secret_key_base: String.duplicate("conformance", 8),
    request_state_salt: "conformance request_state"

  alias Phantom.Session
  require Phantom.Tool, as: Tool
  require Phantom.Prompt, as: Prompt
  require Phantom.Resource, as: Resource
  alias Phantom.ClientLogger

  # 1x1 red PNG pixel and a minimal WAV file, identical to the reference server
  @image Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
         )
  @audio Base.decode64!("UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA=")

  # Remembers terminated sessions on one node for the whole cluster, so
  # every node rejects them. An app would use its own storage.
  @terminated_sessions {:global, Phantom.Conformance.TerminatedSessions}

  def connect(session, _conn) do
    if session.id in terminated_sessions(),
      do: {:not_found, "Session terminated"},
      else: {:ok, session}
  end

  def terminate(session) do
    terminated_sessions()
    Agent.update(@terminated_sessions, &MapSet.put(&1, session.id))
    {:ok, session}
  end

  defp terminated_sessions do
    case Agent.start(fn -> MapSet.new() end, name: @terminated_sessions) do
      {:ok, _pid} -> MapSet.new()
      {:error, {:already_started, pid}} -> Agent.get(pid, & &1)
    end
  end

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
    description: "Tests server-initiated sampling (LLM completion request)" do
    field :prompt, :string, required: true, description: "The prompt to send to the LLM"
  end

  tool :test_elicitation,
    description: "Tests server-initiated elicitation (user input request)" do
    field :message, :string, required: true, description: "The message to show the user"
  end

  tool :test_elicitation_sep1034_defaults,
    description: "Tests elicitation with default values per SEP-1034"

  tool :test_elicitation_sep1330_enums,
    description: "Tests elicitation with enum schema improvements per SEP-1330"

  # The scenario checks that a raw JSON Schema passes through unchanged, which
  # is the map-form `input_schema` use case.
  tool :json_schema_2020_12_tool,
    description: "Tool with JSON Schema 2020-12 features for conformance testing (SEP-1613)",
    input_schema: %{
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      type: "object",
      "$defs": %{
        address: %{
          "$anchor": "addressDef",
          type: "object",
          properties: %{street: %{type: "string"}, city: %{type: "string"}}
        }
      },
      properties: %{
        name: %{type: "string"},
        address: %{"$ref": "#/$defs/address"},
        contactMethod: %{type: "string", enum: ["phone", "email"]},
        phone: %{type: "string"},
        email: %{type: "string"}
      },
      allOf: [%{anyOf: [%{required: ["phone"]}, %{required: ["email"]}]}],
      if: %{properties: %{contactMethod: %{const: "phone"}}, required: ["contactMethod"]},
      then: %{required: ["phone"]},
      else: %{required: ["email"]},
      additionalProperties: false
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

  ## MCP 2026-07-28 fixtures
  #
  # The reference server only serves these on its stateless path. Their
  # `inputRequests` keys are asserted by the suite, so they are built with
  # `Tool.input_required/1` instead of `Session.elicit/3`, which cannot name
  # its key. `inputResponses` are read from the request because Phantom only
  # merges the `"elicitation"` response into the handler params.

  tool :test_missing_capability, description: "Test tool requiring sampling"

  tool :test_input_required_result_elicitation,
    description: "MRTR: returns InputRequiredResult with elicitation request"

  tool :test_input_required_result_sampling,
    description: "MRTR: returns InputRequiredResult with sampling request"

  tool :test_input_required_result_list_roots,
    description: "MRTR: returns InputRequiredResult with roots/list request"

  tool :test_input_required_result_request_state,
    description: "MRTR: returns InputRequiredResult with requestState"

  tool :test_input_required_result_multiple_inputs,
    description: "MRTR: returns InputRequiredResult with multiple input requests"

  tool :test_input_required_result_multi_round,
    description: "MRTR: multi-round InputRequiredResult workflow"

  tool :test_input_required_result_tampered_state,
    description: "MRTR: HMAC-signed requestState integrity test"

  tool :test_input_required_result_capabilities,
    description: "MRTR: respects client capabilities in inputRequests"

  tool :test_streaming_elicitation,
    description: "Diagnostic tool validating response progress streams"

  tool :test_logging_tool, description: "Diagnostic logging validator tool"
  tool :test_trigger_tool_change, description: "Triggers notifications/tools/list_changed"
  tool :test_trigger_prompt_change, description: "Triggers notifications/prompts/list_changed"

  # Not in the reference server. `field` cannot express the `x-mcp-header`
  # extension keyword, so this uses the map form.
  tool :test_custom_headers,
    description: "A tool with x-mcp-header annotations (SEP-2243)",
    input_schema: %{
      type: "object",
      required: [:region, :query],
      properties: %{
        region: %{type: "string", "x-mcp-header": "Region"},
        priority: %{type: "integer", "x-mcp-header": "Priority"},
        query: %{type: "string"}
      }
    }

  def test_custom_headers(params, session) do
    {:reply, Tool.text("Custom headers tool called with: #{JSON.encode!(params)}"), session}
  end

  def test_missing_capability(_params, session) do
    if session.client_capabilities[:sampling] do
      {:reply, Tool.text("Success"), session}
    else
      {:error, Phantom.Request.missing_capability(["sampling"]), session}
    end
  end

  def test_input_required_result_elicitation(_params, session) do
    case input_responses(session) do
      %{"user_name" => response} ->
        {:reply, Tool.text("Hello, #{input_text(response, "name")}!"), session}

      _ ->
        {:reply,
         Tool.input_required(
           input_requests: %{"user_name" => elicit_request("What is your name?", "name")}
         ), session}
    end
  end

  def test_input_required_result_sampling(_params, session) do
    case input_responses(session) do
      %{"sample_request" => %{"content" => %{"text" => text}}} ->
        {:reply, Tool.text("Sampling result: #{text}"), session}

      %{"sample_request" => _} ->
        {:reply, Tool.text("Sampling result: no response"), session}

      _ ->
        {:reply,
         Tool.input_required(
           input_requests: %{
             "sample_request" => sampling_request("What is the capital of France?", 100)
           }
         ), session}
    end
  end

  def test_input_required_result_list_roots(_params, session) do
    case input_responses(session) do
      %{"roots_request" => response} ->
        {:reply, Tool.text("Found #{length(response["roots"] || [])} root(s)"), session}

      _ ->
        {:reply, Tool.input_required(input_requests: %{"roots_request" => roots_request()}),
         session}
    end
  end

  def test_input_required_result_request_state(_params, session) do
    case {session.state, input_responses(session)} do
      {%{kind: :request_state}, %{"confirm" => %{"content" => %{"ok" => true}}}} ->
        {:reply, Tool.text("state-ok: requestState validated"), session}

      _ ->
        {:reply,
         Tool.input_required(
           input_requests: %{"confirm" => elicit_request("Please confirm", "ok", "boolean")},
           state: %{kind: :request_state}
         ), session}
    end
  end

  def test_input_required_result_multiple_inputs(_params, session) do
    case {session.state, input_responses(session)} do
      {%{kind: :multiple_inputs},
       %{"user_name" => name, "greeting" => greeting, "client_roots" => roots}} ->
        greeting = get_in(greeting, ["content", "text"]) || "Hello there!"
        roots = length(roots["roots"] || [])

        {:reply,
         Tool.text("Name: #{input_text(name, "name")}; Greeting: #{greeting}; Roots: #{roots}"),
         session}

      _ ->
        {:reply,
         Tool.input_required(
           input_requests: %{
             "user_name" => elicit_request("What is your name?", "name"),
             "greeting" => sampling_request("Generate a greeting", 50),
             "client_roots" => roots_request()
           },
           state: %{kind: :multiple_inputs}
         ), session}
    end
  end

  def test_input_required_result_multi_round(_params, session) do
    case {session.state, input_responses(session)} do
      {%{round: 1}, %{"step1" => response}} ->
        {:reply,
         Tool.input_required(
           input_requests: %{
             "step2" => elicit_request("Step 2: What is your favorite color?", "color")
           },
           state: %{round: 2, name: input_text(response, "name")}
         ), session}

      {%{round: 2, name: name}, %{"step2" => response}} ->
        {:reply,
         Tool.text("Multi-round complete for #{name} who likes #{input_text(response, "color")}"),
         session}

      _ ->
        {:reply,
         Tool.input_required(
           input_requests: %{"step1" => elicit_request("Step 1: What is your name?", "name")},
           state: %{round: 1}
         ), session}
    end
  end

  # Phantom authenticates and encrypts `requestState`, so tampered state is
  # rejected before this handler runs.
  def test_input_required_result_tampered_state(_params, session) do
    case {session.state, input_responses(session)} do
      {%{kind: :tamper_test}, %{"confirm" => _}} ->
        {:reply, Tool.text("integrity-ok: state verified"), session}

      _ ->
        {:reply,
         Tool.input_required(
           input_requests: %{"confirm" => elicit_request("Please confirm", "ok", "boolean")},
           state: %{kind: :tamper_test}
         ), session}
    end
  end

  def test_input_required_result_capabilities(_params, session) do
    caps = session.client_capabilities

    input_requests =
      %{}
      |> then(
        &if caps[:elicitation],
          do: Map.put(&1, "elicit_input", elicit_request("Elicitation input", "value")),
          else: &1
      )
      |> then(
        &if caps[:sampling],
          do: Map.put(&1, "sample_input", sampling_request("Sample request", 50)),
          else: &1
      )

    cond do
      map_size(input_responses(session)) > 0 ->
        keys = session |> input_responses() |> Map.keys() |> Enum.join(",")
        {:reply, Tool.text("capabilities-ok: received #{keys}"), session}

      map_size(input_requests) == 0 ->
        {:reply, Tool.text("No supported capabilities declared"), session}

      true ->
        {:reply,
         Tool.input_required(input_requests: input_requests, state: %{kind: :capabilities_test}),
         session}
    end
  end

  def test_streaming_elicitation(_params, session) do
    Task.start(fn ->
      Session.notify_progress(session, 50, 100)
      Session.respond(session, Tool.text("Streaming complete"))
    end)

    {:noreply, session}
  end

  def test_logging_tool(_params, session) do
    Task.start(fn ->
      ClientLogger.log(session, :info, "Diagnostic trace logging activated", "conformance")
      Session.respond(session, Tool.text("Logging evaluated"))
    end)

    {:noreply, session}
  end

  def test_trigger_tool_change(_params, session) do
    Phantom.Tracker.notify_tool_list()
    {:reply, Tool.text("Mutation triggered"), session}
  end

  def test_trigger_prompt_change(_params, session) do
    Phantom.Tracker.notify_prompt_list()
    {:reply, Tool.text("Mutation triggered"), session}
  end

  defp input_responses(%Session{request: %{params: %{"inputResponses" => responses}}})
       when is_map(responses),
       do: responses

  defp input_responses(_session), do: %{}

  defp input_text(response, field), do: get_in(response, ["content", field])

  defp elicit_request(message, field, type \\ "string") do
    %{
      method: "elicitation/create",
      params: %{
        message: message,
        requestedSchema: %{
          type: "object",
          properties: %{field => %{type: type}},
          required: [field]
        }
      }
    }
  end

  defp sampling_request(text, max_tokens) do
    %{
      method: "sampling/createMessage",
      params: %{
        messages: [%{role: "user", content: %{type: "text", text: text}}],
        maxTokens: max_tokens
      }
    }
  end

  defp roots_request, do: %{method: "roots/list", params: %{}}

  ## Resources

  resource "test://static-text", :static_text,
    description: "A static text resource for testing",
    mime_type: "text/plain"

  resource "test://static-binary", :static_binary,
    description: "A static binary resource (image) for testing",
    mime_type: "image/png"

  resource "test://template/:id/data", :template,
    description: "A resource template with parameter substitution",
    mime_type: "application/json"

  resource "test://watched-resource", :watched_resource,
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

  prompt :test_input_required_result_prompt,
    description: "MRTR: prompt that requires elicitation input"

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

  def test_input_required_result_prompt(_params, session) do
    case input_responses(session) do
      %{"user_context" => response} ->
        {:reply,
         Prompt.response(
           user: Prompt.text("Prompt with context: #{input_text(response, "context")}")
         ), session}

      _ ->
        {:reply,
         Prompt.input_required(
           input_requests: %{
             "user_context" => elicit_request("What context should the prompt use?", "context")
           }
         ), session}
    end
  end

  def complete_argument(_argument, _value, session) do
    {:reply, %{values: [], total: 0, has_more: false}, session}
  end
end

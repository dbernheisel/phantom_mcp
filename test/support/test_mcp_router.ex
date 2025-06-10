defmodule Test.MCPRouter do
  @instructions """
  A test MCP server for the purpose of end-to-end tests.
  Please call all available tools, prompts, and resources.
  """

  use Phantom.Router,
    name: "Test",
    vsn: "1.0",
    instructions: @instructions

  require Logger

  def connect(session) do
    Logger.info("Connected")
    {:ok, session}
  end

  tool(:explode_tool, description: "Always throws an exception")
  tool(:binary_tool, description: "A binary tool")
  tool(:text_tool, OtherModule, description: "A test tool")

  tool(:echo_tool,
    description: "A test that echos your message",
    input_schema: %{
      required: [:message],
      properties: %{
        message: %{
          type: "string",
          description: "message to echo"
        }
      }
    }
  )

  prompt(:explode_prompt, description: "Always throws an exception")
  prompt(:binary_prompt, description: "An image prompt")
  prompt(:resource_prompt, description: "A resource prompt")

  prompt(:text_prompt, OtherModule,
    description: "A text prompt",
    completion_function: :text_prompt_complete,
    arguments: [
      %{
        name: "code",
        description: "The code to review",
        required: true
      }
    ]
  )

  resource("test:///example/2/:id", OtherModule, :binary_resource,
    completion_function: :binary_resource_complete,
    description: "An image resource",
    mime_type: "image/png"
  )

  resource("test:///example/:id", :text_resource,
    description: "A text resource",
    mime_type: "application/json"
  )

  resource("test:///example/many/:id", :text_resource_many,
    description: "Many text resources",
    mime_type: "application/json"
  )

  resource("test:///example/unfound/:id", :resource_unfound,
    description: "Unfound resources",
    mime_type: "application/json"
  )

  def binary_tool(_params, _request, session) do
    {:reply,
     %{
       type: "image",
       data: Base.encode64(File.read!("test/support/test.png")),
       mime_type: "image/png"
     }, session}
  end

  def explode_tool(_params, _request, _session), do: raise("boom")

  def echo_tool(params, _request, session) do
    {:reply, %{type: "text", text: params["message"]}, session}
  end

  def explode_prompt(_params, _request, _session), do: raise("boom")

  def binary_prompt(_params, _request, session) do
    {:reply,
     %{
       role: :assistant,
       type: "image",
       data: Base.encode64(File.read!("test/support/test.png")),
       mime_type: "image/png"
     }, session}
  end

  def resource_prompt(_params, _request, session) do
    case resource_for(session, :text_resource, id: 321) do
      {:ok, resource} ->
        {:reply,
         %{
           role: :assistant,
           resource: resource
         }, session}

      error ->
        error
    end
  end

  def text_resource(params, _request, session) do
    {:reply, %{text: params}, session}
  end

  def text_resource_many(params, _request, session) do
    data = for i <- 1..10, do: %{text: Map.put(params, :i, i)}
    {:reply, data, session}
  end
end

defmodule OtherModule do
  def binary_resource(%{"id" => "foo"}, _request, session) do
    {:reply, %{mime_type: "image/png", blob: Base.encode64(File.read!("test/support/foo.png"))},
     session}
  end

  def binary_resource(%{"id" => "bar"}, _request, session) do
    {:reply, %{mime_type: "image/png", blob: Base.encode64(File.read!("test/support/bar.png"))},
     session}
  end

  def binary_resource(%{"id" => _}, _request, session) do
    {:reply, %{mime_type: "image/png", blob: Base.encode64(File.read!("test/support/bar.png"))},
     session}
  end

  def binary_resource_complete("id", _value, session) do
    {:reply, ~w[foo bar baz], session}
  end

  def text_tool(_params, _request, session) do
    {:reply,
     [
       %{type: :text, text: "other module"},
       %{error: true, type: :text, text: "an error"}
     ], session}
  end

  def text_prompt_complete("code", _value, session) do
    {:reply,
     %{
       values: ~w[one two],
       has_more: false,
       total: 2
     }, session}
  end

  def text_prompt(params, _request, session) do
    {:reply,
     %{
       role: :user,
       type: :text,
       text: "Please review this Elixir code:\n#{params["code"]}"
     }, session}
  end
end

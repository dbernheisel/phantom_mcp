defmodule Test.MCP.Router do
  @base "test/support/fixtures"

  @instructions """
  A test MCP server for the purpose of end-to-end tests.
  Please call all available tools, prompts, and resources.
  """

  use Phantom.Router,
    name: "Test",
    vsn: "1.0",
    instructions: @instructions

  alias Phantom.Session
  require Phantom.Tool, as: Tool
  require Phantom.Prompt, as: Prompt
  require Phantom.Resource, as: Resource

  def connect(session, %{headers: _headers, params: _params}) do
    {:ok, session}
  end

  @salt "cursor"
  def list_resources(cursor, session) do
    {:ok, uri1, _spec} = resource_for(session, :binary_resource, id: "foo")
    {:ok, uri2, spec} = resource_for(session, :binary_resource, id: "bar")

    binary_resources = [
      Resource.resource_link(uri1, spec, name: "Binary Foo"),
      Resource.resource_link(uri2, spec, name: "Binary Bar")
    ]

    cursor =
      if cursor do
        {:ok, cursor} = Phoenix.Token.verify(Test.Endpoint, @salt, cursor)
        cursor
      else
        0
      end

    resource_links =
      binary_resources ++
        Enum.map(3..1000, fn i ->
          {:ok, uri, spec} = resource_for(session, :text_resource, id: i)
          Resource.resource_link(uri, spec, name: "Resource #{i}")
        end)

    {_before_cursor, after_cursor} =
      resource_links |> Enum.with_index() |> Enum.split_while(fn {_, i} -> i < cursor end)

    {page, [{next, _} | _drop]} = Enum.split(after_cursor, 100)
    next_cursor = Phoenix.Token.sign(Test.Endpoint, @salt, next)
    page = Enum.map(page, &elem(&1, 0))

    {:reply, Resource.list(page, next_cursor), session}
  end

  tool :explode_tool, description: "Always throws an exception"
  tool :binary_tool, mime_type: "image/png", description: "A binary tool"
  tool :audio_tool, description: "An audio tool"
  tool :with_error_tool, description: "A test tool with an error"
  tool :elicit_tool, description: "A tool that always needs info"

  for i <- 0..200 do
    tool :"zzz_tool_#{String.pad_leading(to_string(i), 3, "0")}",
      description: "do not use",
      function: :zzz_tool
  end

  def zzz_tool(_params, session) do
    {:reply, Tool.text("foo"), session}
  end

  for i <- 0..200 do
    prompt :"zzz_prompt_#{String.pad_leading(to_string(i), 3, "0")}",
      description: "do not use",
      function: :zzz_prompt
  end

  def zzz_prompt(_params, session) do
    {:reply, Prompt.response(user: Prompt.text("foo")), session}
  end

  tool :async_embedded_resource_tool, AsyncModule,
    description: "An asyncronous embedded resource tool"

  tool :embedded_resource_tool, AsyncModule, description: "A embedded resource tool"
  tool :embedded_resource_link_tool, AsyncModule, description: "A embedded resource link tool"

  tool :echo_tool,
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

  tool :structured_echo_tool,
    description: "A test that echos your message",
    input_schema: %{
      required: [:message],
      properties: %{
        message: %{
          type: "string",
          description: "message to echo"
        }
      }
    },
    output_schema: %{
      required: [:message],
      properties: %{
        message: %{
          type: "string",
          description: "echo"
        }
      }
    }

  tool :really_long_async_tool, AsyncModule, description: "this will notify of progress"
  tool :timeout_async_tool, AsyncModule, description: "this will timeout!"

  @audio File.read!(@base <> "/game-over.wav")
  def audio_tool(_params, session) do
    {:reply, Tool.audio(@audio, mime_type: "audio/wav"), session}
  end

  @description "A test that echos your message slowly"
  tool :async_echo_tool, AsyncModule,
    input_schema: %{
      required: [:message],
      properties: %{
        message: %{
          type: "string",
          description: "message to echo"
        }
      }
    }

  prompt :explode_prompt, description: "Always throws an exception"
  prompt :binary_prompt, description: "An image prompt"
  prompt :resource_prompt, description: "A resource prompt"

  prompt :async_resource_prompt, AsyncModule,
    description: "A resource prompt that has an async read"

  prompt :text_prompt,
    description: "A text prompt",
    completion_function: :text_prompt_complete,
    arguments: [
      %{
        name: "code",
        description: "The code to review",
        required: true
      }
    ]

  resource "myapp:///binary/:id", AsyncModule, :binary_resource,
    completion_function: :binary_resource_complete,
    description: "An image resource",
    mime_type: "image/png"

  @description "Many text resources"
  resource "test:///text/many/:id", :text_resource_many
  resource "test:///text/:id", :text_resource, description: "A text resource"
  resource "explode:///:id", :explode_resource, description: "One that explodes!"

  @description "These are not the resources you are looking for"
  resource "test:///unfound/:id", :resource_unfound

  @test_png File.read!(@base <> "/test.png")
  def binary_tool(_params, session) do
    {:reply, Phantom.Tool.image(@test_png, foo: :bar), session}
  end

  def explode_tool(_params, _session), do: raise("boom")

  def echo_tool(params, session) do
    {:reply, Phantom.Tool.text(params["message"] || ""), session}
  end

  @elicit_name Phantom.Elicit.build(%{
                 message: "What is your info?",
                 requested_schema: [
                   %{
                     type: :string,
                     name: "name",
                     required: true,
                     title: "Your name",
                     description: "for real"
                   },
                   %{
                     type: :string,
                     name: "email",
                     required: true,
                     title: "Your email",
                     description: "for realisies",
                     pattern: Regex.source(~r/^[^@]+@[^@]+\.[^@]+$/),
                     format: :email
                   }
                 ]
               })
  def elicit_tool(_params, session) do
    with {:ok, request_id} <- Session.elicit(session, @elicit_name),
         {:ok, response} <- await_elicitation(request_id) do
      case response["name"] do
        :error -> {:reply, Phantom.Request.invalid_params("Did not receive name"), session}
        name -> {:reply, Tool.text(%{hello: "my name is #{name}"}), session}
      end
    else
      :not_supported ->
        {:reply, Tool.text(%{hello: "my name is Joe Schmoe"}), session}
    end
  end

  defp await_elicitation(request_id) do
    receive do
      {:response, ^request_id, response} ->
        if response["action"] == "accept" do
          {:ok, response["content"]}
        else
          :error
        end
    after
      10_000 -> :error
    end
  end

  def structured_echo_tool(params, session) do
    {:reply, Phantom.Tool.text(%{message: params["message"] || ""}), session}
  end

  def with_error_tool(_params, session) do
    {:reply, Tool.error("an error"), session}
  end

  def explode_prompt(_params, _session), do: raise("boom")

  def binary_prompt(_params, session) do
    {:reply, Phantom.Prompt.response(assistant: Phantom.Prompt.image(@test_png, "image/png")),
     session}
  end

  def resource_prompt(_params, session) do
    case read_resource(session, :text_resource, id: 321) do
      {:ok, uri, resource} ->
        {:reply,
         Phantom.Prompt.response(
           assistant: Phantom.Prompt.embedded_resource(uri, resource),
           user: Phantom.Prompt.text("Wowzers")
         ), session}

      error ->
        error
    end
  end

  def text_prompt_complete("code", _value, session) do
    {:reply,
     %{
       values: ~w[one two],
       has_more: false,
       total: 2
     }, session}
  end

  def text_prompt(params, session) do
    {:reply,
     Prompt.response(
       assistant: Prompt.text("You are an Elixir expert"),
       user: Prompt.text("Please review this Elixir code:\n#{params["code"]}")
     ), session}
  end

  def text_resource(params, session) do
    {:reply, Phantom.Resource.text(params), session}
  end

  def explode_resource(_params, _session), do: raise("boom")

  def resource_unfound(_params, session) do
    {:reply, nil, session}
  end

  def text_resource_many(_params, session) do
    data =
      for i <- 1..10 do
        Phantom.Resource.text(to_string(i))
      end

    {:reply, data, session}
  end
end

defmodule AsyncModule do
  @timeout Application.compile_env(:phantom_mcp, :timeout, 0)
  @base "test/support/fixtures"

  require Phantom.Tool, as: Tool
  require Phantom.Prompt, as: Prompt
  require Phantom.Resource, as: Resource
  require Phantom.Session, as: Session, warn: false
  require Phantom.ClientLogger, as: ClientLogger

  @foo_png File.read!(@base <> "/foo.png")
  def binary_resource(%{"id" => "foo"}, session) do
    {:reply, Resource.blob(@foo_png, mime_type: "image/png"), session}
  end

  @bar_png File.read!(@base <> "/bar.png")
  def binary_resource(%{"id" => "bar"}, session) do
    ClientLogger.info("An info log")
    pid = session.pid
    request_id = session.request.id

    Task.async(fn ->
      Process.sleep(@timeout)

      Session.respond(
        pid,
        request_id,
        Resource.response(Resource.blob(@bar_png, mime_type: "image/png"))
      )
    end)

    {:noreply, session}
  end

  def binary_resource_complete("id", _value, session) do
    {:reply, ~w[foo bar], session}
  end

  def async_echo_tool(params, session) do
    request_id = session.request.id
    pid = session.pid

    Task.async(fn ->
      Process.sleep(@timeout)

      Session.respond(
        pid,
        request_id,
        Phantom.Tool.text(params["message"] || "")
      )
    end)

    {:noreply, session}
  end

  def really_long_async_tool(params, session) do
    request_id = session.request.id
    progress_token = Session.progress_token(session)
    pid = session.pid

    Task.async(fn ->
      for i <- 1..4 do
        Process.sleep(@timeout * 5)
        Session.notify_progress(pid, progress_token, i, 4)
      end

      Session.respond(
        pid,
        request_id,
        Phantom.Tool.text(params["message"] || "")
      )
    end)

    {:noreply, session}
  end

  def timeout_async_tool(params, session) do
    ClientLogger.log(session, :warning, %{message: "This will timeout"}, "database")

    Task.async(fn ->
      Process.sleep(@timeout * 15)
      Session.respond(session, Phantom.Tool.text(params["message"] || ""))
    end)

    {:noreply, session}
  end

  def embedded_resource_tool(_params, session) do
    with {:ok, uri, resource} <-
           Test.MCP.Router.read_resource(session, :binary_resource, id: "bar") do
      {:reply, Tool.embedded_resource(uri, resource), session}
    end
  end

  def embedded_resource_link_tool(_params, session) do
    with {:ok, uri, resource_template} <-
           Test.MCP.Router.resource_for(session, :binary_resource, id: "foo") do
      {:reply, Tool.resource_link(uri, resource_template), session}
    end
  end

  def async_embedded_resource_tool(_params, session) do
    with {:ok, uri, resource} <-
           Test.MCP.Router.read_resource(session, :binary_resource, id: "foo") do
      {:reply, Tool.embedded_resource(uri, resource), session}
    end
  end

  def async_resource_prompt(_params, session) do
    case Test.MCP.Router.read_resource(session, :binary_resource, id: "foo") do
      {:ok, uri, resource} ->
        {:reply,
         Phantom.Prompt.response(
           assistant: Phantom.Prompt.embedded_resource(uri, resource),
           user: Phantom.Prompt.text("Wowzers")
         ), session}

      error ->
        error
    end
  end
end

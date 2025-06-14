# Phantom MCP

# Work in progress. Do not use.

[![Hex.pm](https://img.shields.io/hexpm/v/phantom.svg)](https://hex.pm/packages/phantom)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/phantom)

<!-- MDOC -->

MCP (Model Context Protocol) framework for Elixir Plug.

This library provides a complete implementation of the [MCP server specification](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports) with Plug.

**Only stateless is tested at this moment. Do not expect stateful (`{:noreply, ...}`) to work**

## Usage Example

For Streamable HTTP access to your MCP server, forward
a path from your Plug or Phoenix Router to your MCP router.

For Phoenix:

```elixir
pipeline :mcp do
  plug :accepts, ["json"]

  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON
end

scope "/mcp" do
  pipe_through :mcp

  forward "/", Phantom.Plug,
    router: MyApp.MCPRouter
end
```

For Plug:

```elixir
defmodule MyAppWeb.Router do
  use Plug.Router

  plug :match
  plug Plug.Parsers,
    parsers: [{:json, length: 1_000_000}],
    pass: ["application/json"],
    json_decoder: JSON
  plug :dispatch

  forward "/mcp",
    to: Phantom.Plug,
    init_opts: [router: MyApp.MCP.Router]
end
```

In your MCP Router, define the available tooling (prompts, resources, tools) and
optional connect and close callbacks.

```elixir
defmodule MyApp.MCPRouter do
  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0"

  require Logger

  # recommended
  def connect(session, _last_event_id) do
    with {:ok, user} <- MyApp.authenticate(conn),
         {:ok, my_session_state} <- MyApp.load_session(session.id) do
      {:ok, assign(session, some_state: my_session_state, user: user)
    end
  end

  # optional
  def disconnect(session) do
    Logger.info("Disconnected: #{inspect(session)}")
  end

  # optional
  def terminate(session) do
    MyApp.archive_session(session.id)
    Logger.info("Session completed: #{inspect(session)}")
  end

  @description """
  Review the provided Study and provide meaningful feedback about the study and let me know if there are gaps or missing questions. We want
  a meaningful study that can provide insight to the research goals stated
  in the study.
  """
  prompt :suggest_questions, MyApp.MCP,
    description: @description,
    completion_function: :study_id_complete,
    arguments: [
      %{
        name: "study_id",
        description: "The study to review",
        required: true
      }
    ]

  # Defining available resources
  @description """
  Read the cover image of a Study to gain some context of the
  audience, research goals, and questions.
  """
  resource "myapp:///studies/:study_id/cover", MyApp.MCP, :study_cover,
    completion_function: :study_id_complete,
    mime_type: "image/png"

  @description """
  Read the contents of a study. This includes the questions and general
  context, which is helpful for understanding research goals.
  """
  resource "https://example.com/studies/:study_id/md", MyApp.MCP, :study,
    completion_function: :study_id_complete,
    mime_type: "text/markdown"

  # Defining available tools
  @description """
  Create a question for the provided Study.
  """
  tool :create_question, MyApp.MCP,
    input_schema: %{
      required: ~w[description label study_id],
      properties: %{
        study_id: %{
          type: "integer",
          description: "The unique identifier for the Study"
        },
        label: %{
          type: "string",
          description: "The title of the Question. The first thing the participant will see when presented with the question"
        },
        description: %{
          type: "string",
          description: "The contents of the question. About one paragraph of detail that defines one question or task for the participant to perform or answer"
        }
      }
    }
  }]
end
```

In the connect callback, you can limit the available tools, prompts, and resources
depending on authorization rules by supplying an allow list of names:

```elixir
  def connect(session, _last_event_id) do
    with {:ok, user} <- MyApp.authenticate(session) do
      {:ok,
        session
        |> assign(:user, user)
        |> limit_for_plan(user.plan)}
    end
  end

  defp limit_for_plan(session, :basic) do
    # allow-list tools by name
    %{session |
      resources: ~w[study],
      tools: ~w[create_question]}
  end

  defp limit_for_plan(session, :ultra), do: session
```

Implement handlers that resemble a GenServer behaviour. Each handler function
will receive three arguments:

1. the params of the request
2. the request
3. the session

```elixir
defmodule MyApp.MCP do
  alias MyApp.Repo
  alias MyApp.Study

  import MyApp.MCPRouter, only: [resource_for: 3], warn: false

  def suggest_questions(%{"study_id" => study_id} = _params, _request, session) do
    case Repo.get(Study, study_id) do
      {:reply, %{
        role: :assistant,
        # Can be "text", "audio", "image", or "resource"
        type: "text",
        # When referencing a resource, supply a `resource: data`
        # You can use the imported `resource_for` helper that will
        # construct a response object pointing to the resource.
        # `resource: resource_for(session, :study, id: study.id)`
        #
        # For binary, supply  `data: base64-encoded-content`
        #
        # Below is an example of text content:
        text: "How was your day?",
        # mime_type can be supplied here, or the default mime_type
        # defined along with the prompt will be used.
        mime_type: "text/plain"
      }, session}
      _ ->
       {:error, "not found"}
    end
  end

  def study(%{"study_id" => id} = params, _request, session) do
    study = Repo.get(Study, id)
    text = Study.to_markdown(study)
    # Must return a map with a `:text` key
    # or a `:binary` key with base64-encoded data.
    {:reply, %{text: text}, session}
  end

  def study_cover(%{"study_id" => id} = params, _request, session) do
    study = Repo.get(Study, id)
    binary = File.read!(study.cover.file)
    {:reply, %{binary: Base.encode64(binary)}, session}
  end

  import Ecto.Query
  def study_id_complete("study_id", value, session) do
    study_ids = Repo.all(
      from s in Study,
        select: s.id,
        where: like(type(:id, :string), "#{value}%"),
        where: s.account_id == ^session.user.account_id,
        limit: 100
      )

    # You may also return a map with more info:
    # `%{values: study_ids, has_more: true, total: 1_000_000}`
    {:reply, study_ids, session}
  end

  def create_question(params, _request, session) do
    %{"study_id" => study_id, "label" => label, "description" => description} = params

    case Study.create_question(study_id, label: label, description: description) do
      {:ok, question} ->
        md = Study.Question.to_markdown(question)
        {:reply, %{type: :text, text: md}, session}
      _ ->
        {:reply, %{type: :text, text: "Could not create", error: true}, session}
    end
  end
end
```

Phantom will implement these MCP requests on your behalf:

- `initialize` accessible in the `connect/2` callback
- `prompts/list` which will list either the allowed prompts in the `connect/2` callback, or all prompts by default
- `prompts/get` which will dispatch the request to your handler
- `resources/list` which will list either the provided resources in the `connect/2` callback, or all resources by default
- `resources/get` which will dispatch the request to your handler
- `resource/templates/list` which will list available as defined in the router.
- `tools/list` which will list either the provided tools in the `connect/2` callback, or all tools by default
- `tools/call` which will dispatch the request to your handler
- `completion/complete` which will dispatch the request to your handler for the given
prompt or resource
- `notification/*` which will be no-op.
- `ping` pong

Batched requests will also be handled transparently. **please note** there is not
an abstraction yet for efficiently providing these as a group to your handler.
The plan is to dispatch the list of params to your handler, and the handler can check
if the params are a list or not.

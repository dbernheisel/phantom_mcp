# Phantom MCP

[![Hex.pm](https://img.shields.io/hexpm/v/phantom_mcp.svg)](https://hex.pm/packages/phantom_mcp)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/phantom_mcp)

<!-- MDOC -->

MCP (Model Context Protocol) framework for Elixir Plug.

This library provides a complete implementation of the [MCP server specification](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports) with Plug.

## Installation

Add Phantom to your dependencies:

```elixir
  {:phantom_mcp, "~> 0.2.0"},
```

Configure MIME to accept SSE

```elixir
# config/config.exs
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}
```

## Usage Example

For Streamable HTTP access to your MCP server, forward
a path from your Plug or Phoenix Router to your MCP router.

For Phoenix:

```elixir
pipeline :mcp do
  plug :accepts, ["json", "sse"]

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

# Add to your config.exs
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}
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
    init_opts: [
      router: MyApp.MCP.Router
    ]
end
```

In your MCP Router, define the available tooling (prompts, resources, tools) and
optional connect and close callbacks.

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0"

  require Logger

  # recommended
  def connect(session, auth_info) do
    # The `auth_info` will depend on the adapter, in this case it's from
    # Plug, so it will be the request headers.
    with {:ok, user} <- MyApp.authenticate(conn, auth_info),
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
  # Be mindful, the input_schema is not validated upon requests.
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
  def connect(session, headers) do
    with {:ok, user} <- MyApp.authenticate(session, headers) do
      {:ok,
        session
        |> assign(:user, user)
        |> limit_for_plan(user.plan)}
    end
  end

  defp limit_for_plan(session, :ultra), do: session
  defp limit_for_plan(session, :basic) do
    # allow-list tools by name
    %{session |
      allowed_resources_templates: ~w[study],
      allowed_tools: ~w[create_question]}
  end
```

Implement handlers that resemble a GenServer behaviour. Each handler function
will generally receive two arguments:

1. the params of the request
2. the session

```elixir
defmodule MyApp.MCP do
  alias MyApp.Repo
  alias MyApp.Study

  import MyApp.MCP.Router, only: [read_resource: 3], warn: false

  def list_resources(cursor, session) do
    # You are still responsible for limiting allowed resources
    cursor =
      if cursor do
        {:ok, cursor} = Phoenix.Token.verify(Test.Endpoint, @salt, cursor)
        cursor
      else
        0
      end

    {_before_cursor, after_cursor} = Enum.split_while(1..1000, fn i -> i < cursor end)
    {page, [next | _drop]} = Enum.split(after_cursor, 100)
    next_cursor = Phoenix.Token.sign(Test.Endpoint, @salt, next)

    resource_links =
      Enum.map(page, fn i ->
        {:ok, uri, spec} = resource_for(session, :text_resource, id: i)
        Resource.resource_link(uri, spec, name: "Resource #{i}")
      end)

    {:reply, %{nextCursor: next_cursor, resources: resource_links}, session}
  end

  def suggest_questions(%{"study_id" => study_id} = _params, session) do
    case read_resource(session, :text_resource, id: 321) do
      {:ok, uri, resource} ->
        {:reply,
         Phantom.Prompt.response(
           assistant: Phantom.Prompt.embedded_resource(uri, resource),
           user: Phantom.Prompt.text("Wowzers")
         ), session}

      error ->
        {:error, nil, session}
    end
  end

  def study(%{"study_id" => id} = params, session) do
    study = Repo.get(Study, id)
    text = Study.to_markdown(study)
    # Use the `Phantom.Resource.text` or `Phantom.Resource.blob` helpers
    {:reply, Phantom.Resource.text(text), session}
  end

  def study_cover(%{"study_id" => id} = params, session) do
    study = Repo.get(Study, id)
    binary = File.read!(study.cover.file)
    # The binary will be base64-encoded by Phantom
    # The default mimetype will also be returned if not specified
    {:reply, Phantom.Resource.blob(binary), session}
  end

  import Ecto.Query
  def study_id_complete("study_id", value, session) do
    study_ids = Repo.all(
      from s in Study,
        select: s.id,
        where: like(type(:id, :string), "#{value}%"),
        where: s.account_id == ^session.user.account_id,
        order_by: s.id,
        limit: 101
      )

    # You may also return a map with more info:
    # `%{values: study_ids, has_more: true, total: 1_000_000}`
    # If you return more than 100, then Phantom will set `has_more: true`
    # and only return the first 100.
    {:reply, study_ids, session}
  end

  def create_question(params, session) do
    %{"study_id" => study_id, "label" => label, "description" => description} = params

    # For illustrative purposes, we'll make this one async
    # Please be mindful that any task that doesn't return within
    # the configured `session_timeout` will be dropped.
    request_id = session.request.id
    pid = session.pid

    Task.async(fn ->
      Process.sleep(1000)
      case Study.create_question(study_id, label: label, description: description) do
        {:ok, question} ->
          Phantom.Session.respond(
            pid,
            request_id,
            Phantom.Tool.text(Study.Question.to_markdown(question))
          )
        _ ->
          Phantom.Session.respond(
            pid,
            request_id,
            Phantom.Tool.error("Could not create")
          )
      end
    end)

    {:noreply, session}
  end
end
```

Phantom will implement these MCP requests on your behalf:

- `initialize`
- `prompts/list` which will list either the allowed prompts in the `connect/2` callback, or all prompts by default
- `prompts/get` which will dispatch the request to your handler
- `resources/list` which will dispatch to your MCP router. By default it will be an empty list until you implement it.
- `resource/templates/list` which will list available as defined in the router.
- `resources/read` which will dispatch the request to your handler.
- `resources/subscribe` only if `pubsub` is provided. The session will subscribe to the `Phantom.Session.resource_subscription_topic()` for the shapes `{:resource_updated, uri}` and `{:resource_updated, name, path_params}`. Upon receiving the update, a notification will be sent to the client.
- `logging/setLevel` only if `pubsub` is provided. Logs can be sent to client
  with `Session.log_{level}(session, map_content)`. [See docs](https://modelcontextprotocol.io/specification/2025-03-26/server/utilities/logging#log-levels). Logs are only sent if the client has initiated an SSE stream.
- `tools/list` which will list either the provided tools in the `connect/2` callback, or all tools by default
- `tools/call` which will dispatch the request to your handler
- `completion/complete` which will dispatch the request to your completion handler for the given prompt or resource.
- `notification/*` which will be no-op.
- `ping` pong

Batched requests will also be handled transparently. **please note** there is not
an abstraction for efficiently providing these as a group to your handler.
Since the MCP specification is deprecating batched request support in the next version, there is no plan to make this more efficient.

Use the [MCP Inspector](https://modelcontextprotocol.io/docs/tools/inspector) to test and verify your MCP server

## Persistent Streams

MCP supports SSE streams to get notifications allow resource subscriptions.
To support this, Phantom needs to track connection pids in your cluster and uses
Phoenix.Tracker (`phoenix_pubsub`) to do this.

MCP will typically have multiple connections to facilitate requests:

1. `POST` for every command, such as `tools/call` or `resources/read`
2. `GET` to start an SSE stream for any events such as logs and notifications.

If the client has not initiated the `GET` SSE stream, then the features will
not be available for that client.

Each `POST` also opens an SSE stream, but immediately closes the connection
once work has completed.

To make Phantom distributed, start the `Phantom.Tracker` and pass in your pubsub server to the `Phantom.Plug`:

```elixir
# Add to your application supervision tree:

{Phoenix.PubSub, name: MyApp.PubSub},
{Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: MyApp.PubSub]},

# Adjust the Phoenix router options to include the PubSub server

forward "/", Phantom.Plug,
  router: MyApp.MCP.Router,
  pubsub: MyApp.PubSub

# or the equivalent Plug.Router options:

forward "/mcp", to: Phantom.Plug, init_opts: [
  router: MyApp.MCP.Router,
  pubsub: MyApp.PubSub
]
```

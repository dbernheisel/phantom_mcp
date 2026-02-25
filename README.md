# Phantom MCP

[![Hex.pm](https://img.shields.io/hexpm/v/phantom_mcp.svg)](https://hex.pm/packages/phantom_mcp)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/phantom_mcp)

<!-- MDOC -->

MCP (Model Context Protocol) framework for Elixir Plug.

This library provides a complete implementation of the [MCP server specification](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports) with Plug.

## Installation

Add Phantom to your dependencies:

```elixir
  {:phantom_mcp, "~> 0.3.4"},
```

## Stdio Transport (Local Clients)

For local-only clients like Claude Desktop, you can expose your MCP server
over stdin/stdout without needing an HTTP server. Add `Phantom.Stdio` to
your supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  {Phantom.Stdio, router: MyApp.MCP.Router}
]
```

For more information about running your MCP server locally with stdio, see
[Phantom.Stdio].

## Streamable HTTP Transport (Remote Clients)

When using with Plug/Phoenix, configure MIME to accept SSE:

```elixir
# config/config.exs
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}
```

For Streamable HTTP access to your MCP server, forward
a path from your Plug or Phoenix Router to your MCP router.

<!-- tabs-open -->

### Phoenix

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  # ...

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
      # Uncomment for remote access from anywhere:
      # origins: :all,
      # Uncomment for remote access from a specified list:
      # origins: ["https://myapp.example"],
      validate_origin: Mix.env() == :prod,
      router: MyApp.MCPRouter
  end
end
```

### Plug.Router

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

Finally, import the formatter settings in your `.formatter.exs`. Below is using Phoenix's
generated example as a starting point.

```elixir
[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phantom_mcp],
  # ...
]
```

<!-- tabs-close -->

Now the fun begins: it's time to define your MCP router that catalogs all your tools, prompts, and resources. When you're creating your MCP server, make sure
you test it with the [MCP Inspector](https://modelcontextprotocol.io/docs/tools/inspector) or your client of choice.

See `Phantom.Plug` for local testing instructions with `mcp-remote`, or
`Phantom.Stdio` for building an escript for direct stdio clients.

First we're define the MCP router:

```elixir
defmodule MyApp.MCP.Router do
  @moduledoc """
  Provides tools, prompts, and resources to aide in researching
  topics and creating research studies using the platform {MyApp}.
  """

  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0",
    instructions: @moduledoc
end
```

I used the `@moduledoc` as the same documentation for the client; feel free to separate
the instructions from internal documentation.

> #### Instructions and descriptions are important! {: .neutral}
>
> These instructions and descriptions for tools, prompts, and resources
> will be used by the LLM to determine when and how to use your tooling.
> Don't be too verbose, but also don't have vague instructions.

You likely need to consider authentication, so look at `m:Phantom#module-authentication-and-authorization`
for how to implement it; tldr, implement the `c:Phantom.Router.connect/2` callback and return `{:ok, session}`
upon success.

Now we'll go through each one and show how to respond synchronously or asynchronously.

## Defining Tools

You can define tools that have an optional `input_schema` and an optional `output_schema`.
If no `input_schema` is provided, then the client will not know to send arguments to your handlers.

```elixir
defmodule MyApp.MCP.Router do
  # ...

  # Defining available tools
  # the `@description` attribute will automatically be read, or you can provide `:description` directly.
  @description """
  Create a question for the provided Study.
  """
  tool :create_question,
    # Provide a handler. If not provided, the current module will be assumed.
    MyApp.MCP,
    # Provide an `input_schema`.
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
end
```

Then implement it:

<!-- tabs-open -->

### Synchronously

```elixir
# If outside of the Router, you'll want to `require Phantom.Tool`.
# If implementing in the router, this will already be required.
require Phantom.Tool, as: Tool

def create_question(%{"study_id" => study_id} = params, session) do
  changeset = MyApp.Question.changeset(%Question{}, params)
  with {:ok, question} <- MyApp.Repo.insert(changeset),
       {:ok, uri, resource_template} <-
            MyApp.MCP.Router.resource_for(session, :question, id: question.id) do
    {:reply, Tool.resource_link(uri, resource_template), session}
  else
    _ -> {:reply, Tool.error("Invalid paramaters"), session}
  end
end
```

### Asynchronously

```elixir
# If outside of the Router, you'll want to `require Phantom.Tool`.
# If implementing in the router, this will already be required.
require Phantom.Tool, as: Tool

def create_question(%{"study_id" => study_id} = params, session) do
  Task.async(fn ->
    Process.sleep(1000)
    changeset = MyApp.Question.changeset(%Question{}, params)
    with {:ok, question} <- MyApp.Repo.insert(changeset),
        {:ok, uri, resource_template} <-
              MyApp.MCP.Router.resource_for(session, :question, id: question.id) do

      Session.respond(session, Tool.resource_link(uri, resource_template))
    else
      _ ->  Session.respond(session, Tool.error("Invalid paramaters")))
    end
  end)
  {:noreply, session}
end
```

<!-- tabs-close -->

## Defining Prompts

```elixir
defmodule MyApp.MCP.Router do
  # ...

  # Prompts may contain arguments. If there are arguments
  # you may want to also provide a completion function to
  # help the client fill in the argument.

  @description """
  Review the provided Study and provide meaningful feedback about the
  study and let me know if there are gaps or missing questions. We want
  a meaningful study that can provide insight to the research goals stated
  in the study.
  """
  prompt :suggest_questions,
    completion_function: :study_complete,
    arguments: [
      %{
        name: "study_id",
        description: "The study to review",
        required: true
      }
    ]
end
```

Then implement it

<!-- tabs-open -->

### Synchronously

```elixir
require Phantom.Prompt, as: Prompt

def suggest_questions(%{"study_id" => study_id}, session) do
  case MyApp.MCP.Router.read_resource(session, :study, id: study_id) do
    {:ok, uri, resource} ->
      {:reply,
        Prompt.response(
          assistant: Prompt.embedded_resource(uri, resource),
          user: Prompt.text("Wowzers"),
          assistant: Prompt.image(File.read!("foo.png")),
          user: Prompt.text("Seriously, wowzers")
        ), session}

    error ->
      {:error, Phantom.Request.internal_error(), session}
  end
end
```

### Asynchronously

```elixir
require Phantom.Prompt, as: Prompt

def suggest_questions(%{"study_id" => study_id}, session) do
  Task.async(fn ->
    case MyApp.MCP.Router.read_resource(session, :study, id: study_id) do
      {:ok, uri, resource} ->
        Session.respond(session, Prompt.response(
          assistant: Prompt.embedded_resource(uri, resource),
          user: Prompt.text("Wowzers"),
          assistant: Prompt.image(File.read!("foo.png")),
          user: Prompt.text("Seriously, wowzers")
        ))

      error ->
        Session.respond(session, Phantom.Request.internal_error())
    end
  end)
  {:noreply, sessin}
end
```

<!-- tabs-close -->

## Defining Resources

Let's define a resource with a resource template:

```elixir
@description """
Read the cover image of a Study to gain some context of the
audience, research goals, and questions.
"""
resource "myapp:///studies/:study_id/cover", :study_cover,
  completion_function: :study_complete,
  mime_type: "image/png"

@description """
Read the contents of a study. This includes the questions and general
context, which is helpful for understanding research goals.
"""
resource "https://example.com/studies/:study_id/md", :study,
  completion_function: :study_complete,
  mime_type: "text/markdown"
```

Then implement them:

<!-- tabs-open -->

### Synchronously

```elixir
require Phantom.Resource, as: Resource

def study(%{"study_id" => id} = params, session) do
  study = Repo.get(Study, id)
  text = Study.to_markdown(study)
  {:reply, Resource.text(text), session}
end

def study_cover(%{"study_id" => id} = params, session) do
  study = Repo.get(Study, id)
  blob = File.read!(study.cover)
  {:reply, Resource.blob(blob), session}
end

## Implement the completion handler:
import Ecto.Query

def study_complete("study_id", value, session) do
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
```

### Asynchronously

```elixir
require Phantom.Resource, as: Resource

def study(%{"study_id" => id} = params, session) do
  Task.async(fn ->
    Process.sleep(1000)
    study = Repo.get(Study, id)
    text = Study.to_markdown(study)
    Session.respond(session, Resource.response(Resource.text(text)))
  end)

  {:noreply, session}
end

def study_cover(%{"study_id" => id} = params, session) do
  Task.async(fn ->
    Process.sleep(1000)
    study = Repo.get(Study, id)
    blob = File.read!(study.cover)
    Session.respond(session, Resource.response(Resource.blob(blob)))
  end)

  {:noreply, session}
end

## Implement the completion handler:
import Ecto.Query

def study_complete("study_id", value, session) do
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
```

<!-- tabs-close -->

You'll also want to implement `list_resources/2` in your router which is
to provide a list of all available resources in your system and return
resource links to them.

```elixir
@salt "cursor"
def list_resources(cursor, session) do
  # Remember to check for allowed resources according to `session.allowed_resource_templates`
  # Below is a toy implementation for illustrative purposes.
  cursor =
    if cursor do
      {:ok, cursor} = Phoenix.Token.verify(MyApp.Endpoint, @salt, cursor)
      cursor
    else
      0
    end

  {_before_cursor, after_cursor} = Enum.split_while(1..1000, fn i -> i < cursor end)
  {page, [next | _drop]} = Enum.split(after_cursor, 100)
  next_cursor = Phoenix.Token.sign(MyApp.Endpoint, @salt, next)

  resource_links =
    Enum.map(page, fn i ->
      {:ok, uri, spec} = resource_for(session, :study, id: i)
      Resource.resource_link(uri, spec, name: "Study #{i}")
    end)

  {:reply,
    Resource.list(resource_links, next_cursor),
    session}
end
```

You can notify the client of resource updates in case they have subscribed
to any updates for the resource.

```elixir
# Do some work and update some underlying resource,
# then notify any listeners:
{:ok, uri} = MyApp.MCP.Router.resource_uri(:my_resource, id: "foo")
Phantom.Tracker.notify_resource_updated(uri)
```

## What PhantomMCP supports

Phantom will implement these MCP requests on your behalf:

- `initialize`. Phantom will detect what capabilities are available to the client based on the provided tooling defined in the Phantom router.
- `prompts/list` list either the allowed prompts provided in the `connect/2` callback, or all prompts by default. To disable, return `allow_prompts(session, [])` in the `connect/2` callback.
- `prompts/get` dispatch the request to your handler if allowed. Read more in `Phantom.Prompt`.
- `resources/list` dispatch to your MCP router. By default it will be an empty list until you implement it. Read more in `Phantom.Resource`.
- `resource/templates/list` list either the allowed resources as provided in the `connect/2` callback or all resource templates by default. To disable, return `allow_resource_templates(session, [])` in the `connect/2` callback. Read more in `Phantom.ResourceTemplate`.
- `resources/read` dispatch the request to your handler. `Phantom.Resource`.
- `resources/subscribe` available if the MCP router is configured with `pubsub`. To notify of updates for the resource, use `Phantom.Tracker.notify_resource_updated(uri)`.
- `resources/unsubscribe` see above.
- `logging/setLevel` available if the MCP router is configured with `pubsub`. Logs can be sent to client with `Session.log_{level}(session, map_content)`. [See docs](https://modelcontextprotocol.io/specification/2025-03-26/server/utilities/logging#log-levels).
- `tools/list` list either the allowed tools as provided in the `connect/2` callback or all tools by default. To disable, return `allow_tools(session, [])` in the `connect/2` callback.
- `tools/call` dispatch the request to your handler. Read more in `Phantom.Tool`.
- `completion/complete` dispatch the request to your completion handler for the given prompt or resource.
- `notification/*` no-op.
- `ping` pong
- `notifications/resources/list_changed` - The server informs the client the list of resources has updated. This is not done automatically; you will need to trigger this with `Phantom.Tracker.notify_resource_list/0`, but also be mindful of what resources the session may have access to.
- `notifications/prompts/list_changed` - The server informs the client the list of prompts has updated. This is triggered when `Phantom.Cache.add_prompt/2` is called.
- `notifications/tools/list_changed` - The server informs the client the list of tools has updated. This is triggered when `Phantom.Cache.add_tool/2` is called.

Phantom **does not yet support these methods**:

- `roots/list` - The server requests the client to provide a list of files available for interaction. This is like `resources/list` but for the client.
- `sampling/createMessage` - The server requests the client to query their LLM and provide its response. This is for human-in-the-loop agentic actions and could be leveraged when the client requests a prompt from the server.
- `elicitation/create` - The server requests input from
  the client in order to complete a request the client has made of it.

## Batched Requests

Batched requests will also be handled transparently. **please note** there is not an abstraction for efficiently providing these as a group to your handler. Since the MCP specification is deprecating batched request support in the next version, there is no plan to make this more efficient.

## Authentication and Authorization

Phantom does not implement authentication on its own. MCP applications needing authentication should investigate OAuth provider solutions like [Oidcc](https://hex.pm/packages/oidcc) or [Boruta](https://hex.pm/packages/boruta) or [ExOauth2Provider](https://hex.pm/packages/ex_oauth2_provider) and configure the route to serve a discovery endpoint.

1. [MCP authentication and discovery](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization) is not handled by Phantom itself. You will need to implement OAuth2 and provide the discovery mechanisms as described in the specification. In the `connect/2` callback you can return `{:unauthorized, www_authenticate_info}` or `{:forbidden, "error message"}` to inform the client of how to move forward. An `{:ok, session}` result will imply successful auth.

2. Once the authentication flow has been completed, a request to the MCP router should land with an authorization header that can be received and verified in the `connect/2` callback of your MCP router.

3. You may also decide to limit the available tools, prompts, or resources depending on your authorization rules. An example is below.

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0"

  require Logger

  def connect(session, %{headers: auth_info}) do
    # The `auth_info` will depend on the adapter, in this case it's from
    # Plug, so it will contain query parameters and request headers.
    with {:ok, user} <- MyApp.authenticate(conn, auth_info),
         {:ok, my_session_state} <- MyApp.load_session(session.id) do
      {:ok,
        session
        |> assign(some_state: my_session_state, user: user)
        |> limit_for_plan(user.plan)}
    else
      :not_found ->
        # See `Phantom.Plug.www_authenticate/1`
        {:unauthorized, %{
          method: "Bearer",
          resource_metadata:  "https://myapp.com/.well-known/oauth-protected-resource"
        }}
      :not_allowed ->
        {:forbidden, "Please upgrade plan to use MCP server"}
    end
  end

  defp limit_for_plan(session, :ultra), do: session
  defp limit_for_plan(session, :basic) do
    # allow-list tools by stringified name. The name is either supplied as the `name` when defining it, or the stringified function name.
    session
    |> Phantom.Session.allowed_tools(~w[create_question])
    |> Phantom.Session.allowed_resource_templates(~w[study])
  end
```

## Optional callbacks

There are several optional callbacks to help you hook into the lifecycle of the connections.

- `c:Phantom.Router.disconnect/1` means the request has closed, not that the session is finished.
- `c:Phantom.Router.terminate/1` means the session has finished and the client doesn't intend to resume it.

For Telemetry, please see `m:Phantom.Plug#module-telemetry` and `m:Phantom.Router#module-telemetry` for emitted telemetry hooks.

## Persistent Streams

MCP supports SSE streams to get notifications allow resource subscriptions.
To support this, Phantom needs to track connection pids in your cluster and uses
Phoenix.Tracker (`phoenix_pubsub`) to do this.

MCP defines a "Streamable HTTP" protocol, which is typical HTTP and SSE connections but with a certain behavior. MCP will typically have multiple connections to facilitate requests:

1. `POST` for every command, such as `tools/call` or `resources/read`. Phantom will open an SSE stream and then immediately close the connection once work has completed.
2. `GET` to start an SSE stream for any events such as logs and notifications. There is no work to complete with these requests, and therefore is just a "channel" for receiving server requests and notifications. The connection will remain open until either the client or server closes it.

All connections may provide an `mcp-session-id` header to resume a session.

**Not yet supported** is the ability to resume broken connections with missed messages with the `last-event-id` header, however this is planned to be supported with a ttl-expiring distributed circular buffer.

To make Phantom distributed, start the `Phantom.Tracker` and pass in your pubsub module to the `Phantom.Plug` options:

```elixir
# Add to your application supervision tree:

{Phoenix.PubSub, name: MyApp.PubSub},
{Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: MyApp.PubSub]},
```

Adjust the Phoenix router or Plug.Router options to include the PubSub server

<!-- tabs-open -->

### Phoenix

```elixir
forward "/", Phantom.Plug,
  router: MyApp.MCP.Router,
  pubsub: MyApp.PubSub
```

### Plug.Router

```elixir
forward "/mcp", to: Phantom.Plug, init_opts: [
  router: MyApp.MCP.Router,
  pubsub: MyApp.PubSub
]
```

<!-- tabs-close -->

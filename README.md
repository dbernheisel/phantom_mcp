# Phantom MCP

[![Hex.pm](https://img.shields.io/hexpm/v/phantom_mcp.svg)](https://hex.pm/packages/phantom_mcp)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/phantom_mcp)

MCP (Model Context Protocol) framework for Elixir Plug.

This library provides a complete implementation of the [MCP server specification](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports) with Plug.


## Usage Example

For Streamable HTTP access to your MCP server, forward
a path from your Plug or Phoenix Router to your MCP router.

```elixir
defmodule MyAppWeb.Router do
  # ...
  forward "/mcp", to: MyApp.MCPRouter
end
```

In your MCP Router, define the available tooling (prompts, resources, tools) and
optional connect and close callbacks.

```elixir
defmodule MyApp.MCPRouter do
  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0"

  def connect(conn) do
    with {:ok, user} <- MyApp.authenticate(conn) do
      {:ok,
        conn
        |> assign(:user, user)
        |> put_instructions("Optional instructions for the client")}
    end
  end

  # Defining available prompts
  @description """
  Review the provided code and provide meaningful feedback about architecture
  and catch bugs. We're not interested in nitpicks.
  """
  prompt :code_review, MyApp.MCP do
    # Ecto-style schema definition and validation
    param :content, :string, required: true,
        description: "The contents of the code"
  end

  # Defining available resources
  @description """
  Read the contents of a study. The study is structured to have a title,
  audience, research goals, and questions.
  """
  resource "my_app://studies/:id", MyApp.MCP, :studies_read

  @description """
  List the studies that already exist. This is helpful to find other supporting
  evidence or context for new studies.
  """
  resource "my_app://studies", MyApp.MCP, :studies_list

  # Defining available tools
  @description """
  Perform a Foo with a Bar, and get a Baz
  """
  tool :foo, MyApp.MCP do
    # Ecto-style schema definition and validation
    param :bar, :string
  end
end
````

In the connect callback, you can limit the available tools depending on
authorization rules:

```elixir
  def connect(conn) do
    with {:ok, user} <- MyApp.authenticate(conn) do
      {:ok,
        conn
        |> assign(:user, user)
        |> put_instructions("Optional instructions for the client")
        |> put_tools(tools_for_plan(user.plan))}
    end
  end

  defp tools_for_plan(:basic), do: ~w[studies_read studies_list]a
  defp tools_for_plan(:ultra), do: all_tools()
```

Implement handlers that resemble a GenServer behaviour. Each handler function
will receive three arguments:

1. the params of the request
2. the request
3. the underlying transport state (the conn):

```elixir
defmodule MyApp.MCP do
  use Phantom.MCP

  def code_review(%{"content" => content} = _params, _request, conn) do
    # ... do sync work
    {:reply, %{data: :foo}, conn}
  end

  def code_review(%{"content" => content} = _params, request, conn) do
    request_id = request.id

    # async/2 is a wrapper around Task.async that closes
    # the request once Task is down
    {:noreply, async(conn, fn ->
       send_event(request_id, %{"do" => "work"})
    end)}
  end

  def studies_read(%{"uri" => uri} = params, _request, conn) do
    data = MyApp.Repo.get(Study, to_id(uri))
    {:reply, data, conn}
  end

  defp to_id("my_app:///studies/" <> study_id), do: study_id

  def studies_list(_params, request, conn) do
    cursor = request["cursor"] || 0
    studies = MyRepo.all(from s in Study, s.id > ^cursor, order_by: cursor)
    next_cursor = Map.get(List.last(studies) || %{}, :id)
    {:reply, studies, put_next_cursor(conn, next_cursor)}
  end

  def foo(%{"bar" => bar} = _params, _request, conn) do
    {:reply, data, conn}
  end
```

Phantom will implement these MCP requests on your behalf:

- `initialize` accessible in the `connect/2` callback
- `prompts/list` which will list either the provided prompts in the `connect/2` callback, or all prompts by default
- `prompts/get` which will forward the prompt to your handler
- `resources/list` which will list either the provided resources in the `connect/2` callback, or all resources by default
- `resources/get` which will forward the resource to your handler
- `resource/templates/list` which will list available as defined in the router.
- `tools/list` which will list either the provided tools in the `connect/2` callback, or all tools by default
- `tools/call` which will forward the call to your handler
- `notification/*` which will generally no-op.
- `ping` pong

Batched requests will also be handled transparently.

## Session Management

You can enable session management to enable resumable requests.
This makes the MCP more resilient to dropped connections during an LLM
conversation, and enhances the capability of your MCP server, for example, the
session can subscribe to PubSub events to send notifications back to the LLM.

This is also helpful in case you need to store more context throughout the
conversation between the LLM and your MCP server.

Add an supervisor module that will initialize and supervise sessions:

```elixir
defmodule MyApp.MCPSession do
  use Phantom.Session,
    router: MyApp.MCPRouter,
    buffer: 4096, # 4Mb
    timeout: :timer.minutes(5)
end
```

Implement optional callbacks to initialize sessions:

```elixir
  alias Phantom.Session

  def connect(conn) do
    # Find or create session
    session =
      case Session.request_session_id(conn) do
        nil -> new()
        id -> MyRepo.get_by(Session, id) || new()
      end

    Phoenix.PubSub.subscribe(MyApp.PubSub, "user:#{conn.assigns.user.id}")
    {:ok, conn, session}
  end

  defp new(request), do: Session.new(foo: :bar)

  # The reason may be:
  #   :client - The client finished the session
  #   :disconnect - The connection dropped
  #   :timeout - Async work took longer than the allowed time
  #   {:DOWN, ...} - The session process was taken down
  #   any - Any error returned from MCP handlers.

  def terminate(reason, session) do
    :ok
  end
```

Add your Session supervisor to your application supervision tree, before
the endpoint

```elixir
  children = [
    # ...
    MyApp.MCPSession,
    MyApp.Endpoint
    # ...
  ]
```

Then you can enhance your MCP handlers to react to events:

```elixir
defmodule MyApp.MCP do
  # ...

  # If not implementing the `Phantom.MCP.Resource.URI`, you will
  # receive the URI of the resource
  def handle_subscribe("my_app:///studies/" <> study_id, _request, session) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "study:#{study_id}")
  end

  # If implementing the `Phantom.MCP.Resource.URI`, you will
  # receive the URI of the resource
  def handle_subscribe({:study, id}, _request, session) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "study:#{study_id}")
  end

  # Phoenix.PubSub.broadcast!(MyApp.PubSub, "study:123", {:updated, study_id})
  def handle_info(%{topic: "study:" <> _, payload: {:updated, study_id}}, session) do
    study = MyRepo.get_by(Study, study_id)
    {:noreply, notify_resource_changed(session, study)}
  end

  # Phoenix.PubSub.broadcast!(MyApp.PubSub, "user:123", {:updated, user_id})
  def handle_info(%{topic: "user:" <> _, payload: {:updated, user_id}}, session) do
    plan = MyApp.Repo.get(from u in User, where: u.id == ^user_id, select: u.plan)
    {:noreply, notify_tools_changed(session, tools_for_plan(plan))}
  end

  defp tools_for_plan(:basic), do: ~w[studies_read studies_list]a
  defp tools_for_plan(:ultra), do: all_tools()
end

defimpl Phantom.MCP.Resource.URI, for: %Study{} do
  def to_uri(study) do
    {:ok, URI.new("my_app:///studies/#{study.id}")}
  end

  def from_uri("my_app:///studies/" <> study_id) do
    {:ok, {:study, study_id}}
  end
end
```

If the connection drops, async work that is happening will be buffered
in the session process up to the configured size limit. If a connection revives
with the same `Mcp-Session-Id` then the session process will flush the buffered
data to the client. If the client additionally sends the `Last-Event-Id` header,
the session process will flush its buffer from that ID.

After the configured timeout period of inactivity, the connection will close
with reason `:timeout`.

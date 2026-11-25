# Tools

Tools are functions the client's model calls. A tool has a name, a
description, an optional `input_schema`, and an optional `output_schema`. If
no `input_schema` is provided, the client will not know to send arguments to
your handler.

## Defining tools

Use a `do` block with `field` declarations to define the input schema. This
generates JSON Schema for clients **and** validates incoming arguments at
dispatch time. See `Phantom.Tool.JSONSchema` for the full type system and
options reference.

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router, name: "MyApp", vsn: "1.0"

  tool :create_question, MyApp.MCP,
    description: "Create a question for the provided Study." do
    field :study_id, :integer, required: true,
      description: "The unique identifier for the Study"

    field :label, :string, required: true,
      description: "The title of the Question"

    field :description, :string, required: true,
      description: "About one paragraph of detail that defines the question"
  end
end
```

The second argument names the module that implements the tool; without it,
the router implements it. A `do` block needs at least one option before it,
such as `:description`. Fields support nested objects, arrays, enums,
pattern matching, custom validators, and more:

```elixir
tool :search_studies, description: "Search for studies" do
  field :query, :string, required: true
  field :limit, :integer, default: 10, maximum: 100
  field :status, :string, in: ~w[draft active archived]
  field :tags, {:array, :string}

  field :filters, :map do
    field :category, :string
    field :min_price, :number, minimum: 0
  end
end
```

You can also use the map-based `input_schema` option for full control over
the JSON Schema. Clients receive the map as given, so any JSON Schema keyword
works; server-side validation only checks `type`, `required`, `properties`,
`enum`, and `items`. Without a `do` block, you can describe the tool with a
`@description` attribute, which reads better for long descriptions:

```elixir
@description """
Create a question for the provided Study.
"""
tool :create_question, MyApp.MCP,
  input_schema: %{
    required: ~w[study_id label description],
    properties: %{
      study_id: %{type: "integer", description: "The Study ID"},
      label: %{type: "string", description: "The title"},
      description: %{type: "string", description: "The contents"}
    }
  }
```

See `Phantom.Tool` for annotations, icons, output schemas, and every response
helper.

## Implementing tools

A handler receives the arguments and the session, and answers either
synchronously or asynchronously.

### Synchronously

Return `{:reply, result, session}`:

```elixir
# If outside of the Router, you'll want to `require Phantom.Tool`.
# If implementing in the router, this will already be required.
require Phantom.Tool, as: Tool

def create_question(%{"study_id" => study_id} = params, session) do
  changeset = MyApp.Question.changeset(%Question{study_id: study_id}, params)

  with {:ok, question} <- MyApp.Repo.insert(changeset),
       {:ok, uri, resource_template} <-
         MyApp.MCP.Router.resource_for(session, :question, id: question.id) do
    {:reply, Tool.resource_link(uri, resource_template), session}
  else
    _ -> {:reply, Tool.error("Invalid parameters"), session}
  end
end
```

### Asynchronously

Return `{:noreply, session}`, and answer later with
`Phantom.Session.respond/2`:

```elixir
require Phantom.Tool, as: Tool
alias Phantom.Session

def create_question(%{"study_id" => study_id} = params, session) do
  Task.async(fn ->
    changeset = MyApp.Question.changeset(%Question{study_id: study_id}, params)

    with {:ok, question} <- MyApp.Repo.insert(changeset),
         {:ok, uri, resource_template} <-
           MyApp.MCP.Router.resource_for(session, :question, id: question.id) do
      Session.respond(session, Tool.resource_link(uri, resource_template))
    else
      _ -> Session.respond(session, Tool.error("Invalid parameters"))
    end
  end)

  {:noreply, session}
end
```

For work that outlives the request, such as a long job run with Oban, answer
with a task instead; see the [Tasks](tasks.md) guide.

## Limiting tools per session

By default every tool is listed and callable. To limit them, for example by
the user's plan, call `Phantom.Session.allow_tools/2` in
`c:Phantom.Router.connect/2`. See the [Authentication](authentication.md)
guide.

## Adding tools at runtime

Tools defined with `tool` are compiled into the router. To add one while the
application runs, use `Phantom.Cache.add_tool/2`; Phantom notifies clients
with `notifications/tools/list_changed`.

# Resources

Resources are data the client reads by URI, such as a document, a record, or
an image. You define resource templates, URI patterns routed to a handler the
way a Phoenix router routes paths to a controller.

## Defining resources

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router, name: "MyApp", vsn: "1.0"

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
end
```

Path params such as `:study_id` arrive in the handler's params. Build a URI
for a template with `resource_uri/3`, or a URI and its template with
`resource_for/3`, both defined on your router:

```elixir
{:ok, uri} = MyApp.MCP.Router.resource_uri(:study, study_id: 1)
{:ok, uri, resource_template} = MyApp.MCP.Router.resource_for(session, :study, study_id: 1)
```

See `Phantom.ResourceTemplate` for every option.

## Implementing resources

### Synchronously

```elixir
require Phantom.Resource, as: Resource

def study(%{"study_id" => id}, session) do
  study = Repo.get(Study, id)
  {:reply, Resource.text(Study.to_markdown(study)), session}
end

def study_cover(%{"study_id" => id}, session) do
  study = Repo.get(Study, id)
  {:reply, Resource.blob(File.read!(study.cover)), session}
end
```

### Asynchronously

```elixir
require Phantom.Resource, as: Resource
alias Phantom.Session

def study(%{"study_id" => id}, session) do
  Task.async(fn ->
    study = Repo.get(Study, id)
    Session.respond(session, Resource.response(Resource.text(Study.to_markdown(study))))
  end)

  {:noreply, session}
end
```

## Completing path params

The `completion_function` helps the client fill in path params. It works the
same as for prompts; see [Prompts](prompts.md#completing-arguments).

```elixir
def study_complete("study_id", value, session) do
  {:reply, MyApp.Studies.ids_starting_with(session.assigns.user, value), session}
end
```

## Listing resources

`resources/templates/list` lists your templates. `resources/list` lists
concrete resources, and is empty until you implement
`c:Phantom.Router.list_resources/2`, returning resource links to the resources
in your system:

```elixir
@salt "cursor"
def list_resources(cursor, session) do
  # Remember to check for allowed resources according to
  # `session.allowed_resource_templates`.
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
      {:ok, uri, spec} = resource_for(session, :study, study_id: i)
      Resource.resource_link(uri, spec, name: "Study #{i}")
    end)

  {:reply, Resource.list(resource_links, next_cursor), session}
end
```

When the list changes, tell clients with `Phantom.Tracker.notify_resource_list/0`,
mindful of which resources each session may access.

To limit the templates a session sees, call
`Phantom.Session.allow_resource_templates/2` in `c:Phantom.Router.connect/2`;
return `allow_resource_templates(session, [])` to disable them.

## Subscriptions

Clients can subscribe to a resource and be notified when it changes. This
needs a `pubsub` configured on `Phantom.Plug` and `Phantom.Tracker` running;
see [Deployment](deployment.md#persistent-streams).

For bulk writes, collect the changed URIs in your application and notify
Phantom once. This lets Phantom group the resources by subscribed session and
lets your authorization callback use one bulk query per session.

```elixir
# Do a bulk write, then collect the affected URIs from its result.
uris =
  Enum.map(updated_records, fn record ->
    {:ok, uri} = MyApp.MCP.Router.resource_uri(:study, study_id: record.id)
    uri
  end)

Phantom.Tracker.notify_resources_updated(uris)
```

`Phantom.Tracker.notify_resource_updated/1` remains available for individual
changes.

### Authorizing subscriptions

Resource subscriptions are allowed by default. For user-scoped resources,
override `c:Phantom.Router.authorize_resource_subscriptions/2`. Phantom
resolves each URI before invoking the callback, and uses the same callback
both when accepting `resources/subscribe` and immediately before sending
update notifications. The second check ensures permission changes take effect
after subscription.

```elixir
def authorize_resource_subscriptions(resources, session) do
  user = session.assigns.user

  allowed_ids =
    resources
    |> Enum.map(fn {_uri, %{"study_id" => id}, _template} -> id end)
    |> MyApp.Studies.list_authorized_ids(user)
    |> MapSet.new()

  Enum.filter(resources, fn {_uri, %{"study_id" => id}, _template} ->
    id in allowed_ids
  end)
end
```

The callback receives `{uri, path_params, resource_template}` tuples and the
authenticated session. It may return the allowed tuples or just their URI
strings. Returning `nil` or `[]`, raising, or returning an invalid value
rejects the resources. URIs that do not resolve to an available resource
template are rejected before the callback runs.

## Caching responses

Annotate a result with `Phantom.Request.with_cache/2` to let clients and
proxies cache it; see [Deployment](deployment.md#response-caching).

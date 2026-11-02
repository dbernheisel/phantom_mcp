# A2A agents

[A2A](https://a2a-protocol.org) (Agent2Agent) lets a client delegate a whole
job to an agent and follow it as a task, where MCP lets a client's model call
your tools one at a time. Phantom serves A2A v1.0 agents from the same router
as your MCP tools, over the JSON-RPC and HTTP+JSON bindings, with streaming
over SSE and push notifications to webhooks.

| Phantom | You |
|---|---|
| Serves agent cards and the A2A methods, and validates requests | Implement each agent's `handle_message/2` |
| Calls `connect/2` on every request, as for MCP | Authenticate, and assign what the session may use |
| Streams the events you publish to clients, on any node | Store tasks, run the work, and publish each change |
| Checks webhook URLs and delivers push notifications | Store push configs, and deliver from a job queue if deliveries must survive a restart |

## Quick start

Declare agents in your router:

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0",
    a2a: [well_known: "research"]

  agent "research", MyApp.Agents.Research
end
```

Implement the agent. The simplest answers every message with a message:

```elixir
defmodule MyApp.Agents.Research do
  use Phantom.A2A.Agent,
    name: "MyApp Research",
    description: "Designs and reviews research studies"

  @description "Answer questions about study design"
  skill :study_design, tags: ["research"]

  def handle_message(message, ctx) do
    {:reply, Phantom.A2A.Message.agent(MyApp.Research.answer(message)), ctx}
  end
end
```

Serve it. Mount `Phantom.A2A.Plug` without `Plug.Parsers`, so a request with
invalid JSON gets the error A2A requires:

```elixir
# lib/my_app_web/router.ex
get "/.well-known/agent-card.json", Phantom.A2A.Plug,
  router: MyApp.MCP.Router,
  mount: "/a2a"

scope "/a2a" do
  forward "/", Phantom.A2A.Plug, router: MyApp.MCP.Router, pubsub: MyApp.PubSub
end
```

The card is at `/a2a/research/agent-card.json`. The agent answers JSON-RPC at
`POST /a2a/research` and HTTP+JSON below it, such as
`POST /a2a/research/message:send`. Clients must send `A2A-Version: 1.0`. Try it
with the [A2A Inspector](https://github.com/a2aproject/a2a-inspector).

## Tasks

Answer with a `Phantom.A2A.Task` when the work takes a while. Phantom doesn't
store tasks; you do, and you report each change with `Phantom.A2A.publish/2`:

```elixir
def handle_message(message, ctx) do
  task = Phantom.A2A.Task.submitted(ctx)
  MyApp.A2ATasks.start!(task, message, ctx)
  {:reply, task, ctx}
end

def get_task(task_id, ctx), do: MyApp.A2ATasks.get(task_id, ctx.assigns.user)
```

A new task must use `ctx.task_ref.task_id` as its ID, which
`Phantom.A2A.Task.submitted/2` does. The `Phantom.A2A.TaskRef` in `ctx.task_ref`
addresses the task from anywhere, so pass it to the work. Save every change
before you publish it: clients that ask for the task afterwards get it from
`c:Phantom.A2A.Agent.get_task/2`.

What a client sees depends on the method it called:

- `SendMessage` waits until the task finishes or needs input, then answers
  with the task. With `returnImmediately: true` it answers at once. Without a
  `:pubsub` on the plug, it polls `get_task/2` instead of waiting on events. It
  stops waiting after `:blocking_timeout` and answers with the task as it is.
- `SendStreamingMessage` and `SubscribeToTask` stream the task, then each
  event you publish, until it finishes or needs input. They stay open through
  `auth_required`, so an agent that receives the credential out of band can
  carry on in the same stream. `SendMessage` still returns at `auth_required`,
  so the client can authenticate.
- `GetTask` and `ListTasks` read your store.

`get_task/2` is also where you check access: return `{:error, :not_found}`
for a task the session may not see.

### Example: Ecto and Oban

This stores each task as an Erlang term, next to the columns `ListTasks`
filters on, and runs the work in an [Oban](https://hexdocs.pm/oban) job.
`Phantom.A2A.Events.apply/2` applies each event to the stored task with the
rules A2A defines, and numbers it. Publish the numbered event: a client that
subscribes while you publish gets the stored task, and Phantom skips the
events already in it. Number events in the same transaction that locks the
task, so two writers can't number events the same.

```elixir
defmodule MyApp.Repo.Migrations.CreateA2ATasks do
  use Ecto.Migration

  def change do
    create table(:a2a_tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :agent_id, :string, null: false
      add :context_id, :string, null: false
      add :state, :string, null: false
      add :task, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:a2a_tasks, [:user_id, :context_id])
    create index(:a2a_tasks, [:user_id, :updated_at])
  end
end
```

```elixir
defmodule MyApp.A2ATask do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "a2a_tasks" do
    belongs_to :user, MyApp.Accounts.User
    field :agent_id, :string
    field :context_id, :string
    field :state, :string
    field :task, :binary

    timestamps()
  end
end
```

```elixir
defmodule MyApp.A2ATasks do
  import Ecto.Query

  alias MyApp.{A2ATask, Repo}
  alias Phantom.A2A.{Events, Task, TaskRef}

  def start!(%Task{} = task, message, ctx) do
    Repo.transaction(fn ->
      Repo.insert!(%A2ATask{
        id: task.id,
        user_id: ctx.assigns.user.id,
        agent_id: ctx.task_ref.agent_id,
        context_id: task.context_id,
        state: Atom.to_string(task.status.state),
        task: :erlang.term_to_binary(task)
      })

      text = Enum.map_join(message.parts, " ", &(&1.text || ""))
      %{"task_ref" => TaskRef.encode(ctx.task_ref), "text" => text}
      |> MyApp.Workers.Research.new()
      |> Oban.insert!()
    end)
  end

  def get(task_id, user) do
    case Repo.get_by(A2ATask, id: task_id, user_id: user.id) do
      nil -> {:error, :not_found}
      record -> {:ok, to_task(record)}
    end
  end

  @doc "Apply an event to the stored task, then publish the numbered event."
  def emit!(%TaskRef{} = ref, event) do
    {:ok, event} =
      Repo.transaction(fn ->
        record = A2ATask |> lock("FOR UPDATE") |> Repo.get!(ref.task_id)
        {:ok, task, event} = Events.apply(to_task(record), event)

        record
        |> Ecto.Changeset.change(
          state: Atom.to_string(task.status.state),
          task: :erlang.term_to_binary(task)
        )
        |> Repo.update!()

        event
      end)

    Phantom.A2A.publish(ref, event)
  end

  defp to_task(record), do: :erlang.binary_to_term(record.task, [:safe])
end
```

The worker reports progress through the same function:

```elixir
defmodule MyApp.Workers.Research do
  use Oban.Worker, queue: :a2a

  alias Phantom.A2A.{Artifact, Part, Task, TaskRef}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_ref" => encoded, "text" => text}}) do
    {:ok, ref} = TaskRef.decode(encoded)

    MyApp.A2ATasks.emit!(ref, Task.status(:working, "Reading the study"))

    # The first chunk adds the artifact; the rest append to it.
    text
    |> MyApp.Research.review()
    |> Enum.with_index()
    |> Enum.each(fn {chunk, i} ->
      MyApp.A2ATasks.emit!(ref, Artifact.update("review", [Part.text(chunk)], append: i > 0))
    end)

    MyApp.A2ATasks.emit!(ref, Task.status(:completed, "Review ready"))
  end
end
```

### Asking the client for more

To continue a task, a client sends a message with its `taskId`. Phantom
fetches the task with `get_task/2`, refuses one that has finished, and calls
`handle_message/2` again with the same `ctx.task_ref`:

```elixir
# The work asked a question:
MyApp.A2ATasks.emit!(ref, Task.status(:input_required, "Include demographic questions?"))

# The client's answer arrives as a new message for the same task:
def handle_message(%Phantom.A2A.Message{task_id: task_id} = message, ctx)
    when is_binary(task_id) do
  {:ok, task} = MyApp.A2ATasks.get(task_id, ctx.assigns.user)
  MyApp.A2ATasks.resume!(task, message, ctx)
  {:reply, task, ctx}
end
```

### Canceling and listing

Implement `c:Phantom.A2A.Agent.cancel_task/2` to stop the work and return the
canceled task. Phantom refuses to cancel a finished task, and returns an
already canceled one as it is. Without the callback, tasks can't be canceled.

Implement `c:Phantom.A2A.Agent.list_tasks/2` for `ListTasks`. Phantom parses
the filter and trims each task's history and artifacts as the client asked:

```elixir
def list_tasks(filter, ctx) do
  query =
    from t in MyApp.A2ATask,
      where: t.user_id == ^ctx.assigns.user.id,
      order_by: [desc: t.updated_at]

  query = if filter.context_id, do: where(query, context_id: ^filter.context_id), else: query
  query = if filter.status, do: where(query, state: ^Atom.to_string(filter.status)), else: query

  offset = String.to_integer(filter.page_token || "0")
  records = query |> limit(^(filter.page_size + 1)) |> offset(^offset) |> MyApp.Repo.all()
  {page, more} = Enum.split(records, filter.page_size)

  {:ok,
   %{
     tasks: Enum.map(page, &:erlang.binary_to_term(&1.task, [:safe])),
     next_page_token: if(more != [], do: Integer.to_string(offset + filter.page_size))
   }}
end
```

## Authentication and tenants

Each request calls `c:Phantom.Router.connect/2` with the conn, whose
`body_params` hold the request: the JSON-RPC request, or the same shape for
HTTP+JSON. Return `{:unauthorized, info}` for a
401 with `WWW-Authenticate`, or `{:forbidden, message}` for a 403. Agent cards
stay public.

A client may name a `tenant`, such as an organization, in each request. It is
the client's claim, so check it in `connect/2` and assign what the session may
use; handlers then read `ctx.assigns`, not `ctx.tenant`:

```elixir
def connect(session, conn) do
  tenant = get_in(conn.body_params, ["params", "tenant"])

  with {:ok, user} <- MyApp.Auth.verify(conn),
       {:ok, org} <- MyApp.Orgs.for_user(user, tenant) do
    {:ok,
     session
     |> Phantom.Session.assign(user: user, org: org)
     |> Phantom.Session.allow_agents(MyApp.Agents.allowed_for(org))}
  end
end
```

`Phantom.Session.allow_agents/2` takes agent paths, or the paths of routes
with params. A disallowed agent is not found.

## Agents found at runtime

A route with path params serves agents you store, such as ones each
organization configures. Phantom calls the resolver after `connect/2`, with the
params and the session:

```elixir
agent ":org/:agent_key", MyApp.Agents.Hosted, :resolve
```

```elixir
defmodule MyApp.Agents.Hosted do
  use Phantom.A2A.Agent, name: "Hosted", description: "Agents configured per organization"

  def resolve(%{"org" => org, "agent_key" => key}, session) do
    case MyApp.Agents.get(session.assigns.user, org, key) do
      nil ->
        {:error, :not_found}

      agent ->
        card = %Phantom.A2A.Card{
          name: agent.name,
          description: agent.description,
          default_input_modes: ["text/plain"],
          default_output_modes: ["text/plain"]
        }

        {:ok, card, agent}
    end
  end

  def handle_message(message, ctx) do
    task = Phantom.A2A.Task.submitted(ctx)
    MyApp.Agents.start_run!(ctx.agent.state, task, message, ctx)
    {:reply, task, ctx}
  end
end
```

The handler finds the params in `ctx.agent.params` and what the resolver
returned in `ctx.agent.state`. A resolved agent's card needs the session, so
it isn't public. Routes without params match first.

## Push notifications

With `push_notifications: true`, clients can register a webhook for a task,
and Phantom posts each event you publish to it. Store the configs:

```elixir
use Phantom.A2A.Agent,
  name: "MyApp Research",
  description: "Designs and reviews research studies",
  push_notifications: true

def create_push_config(config, ctx), do: MyApp.PushConfigs.create(config, ctx.assigns.user)
def get_push_config(task_id, id, _ctx), do: MyApp.PushConfigs.get(task_id, id)
def list_push_configs(task_id, _ctx), do: {:ok, MyApp.PushConfigs.list(task_id)}
def delete_push_config(task_id, id, _ctx), do: MyApp.PushConfigs.delete(task_id, id)

# Called by publish/2, in the process that publishes, which has no session
def push_configs(task_ref), do: MyApp.PushConfigs.list(task_ref.task_id)
```

Phantom checks the task with `get_task/2` before each config method, and
checks the webhook URL: it must use `https` and resolve only to public
addresses. Delivery checks the URL again, connects to the address it checked,
and doesn't follow redirects. The credentials in a config are the client's
secrets for its own webhook, so store them encrypted.

By default each webhook gets a task's events in order, from a supervised
process. Up to 100 events wait for each webhook in memory, so they end with
the node. For delivery that survives a restart,
override `c:Phantom.A2A.Agent.deliver_push/3` and deliver from a job:

```elixir
def deliver_push(config, event, _task_ref) do
  %{"config_id" => config.id, "event" => Base.encode64(:erlang.term_to_binary(event))}
  |> MyApp.Workers.Push.new()
  |> Oban.insert!()

  :ok
end
```

```elixir
defmodule MyApp.Workers.Push do
  use Oban.Worker, queue: :a2a_push, max_attempts: 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"config_id" => id, "event" => event}}) do
    config = MyApp.PushConfigs.get!(id)
    event = event |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    Phantom.A2A.Push.deliver(config, event)
  end
end
```

Set `a2a: [allow_private_push_urls: true]` on the router to allow `http` and
private addresses, such as in development.

## Extended cards and extensions

With `extended_card: true`, authenticated clients can fetch a fuller card.
Return it from `c:Phantom.A2A.Agent.extended_card/2`, such as with skills only
members may see:

```elixir
def extended_card(card, ctx) do
  {:ok, %{card | skills: card.skills ++ MyApp.Agents.member_skills(ctx.assigns.user)}}
end
```

Declare protocol extensions with the `:extensions` option. Phantom refuses a
request that doesn't name a `required: true` extension in its
`A2A-Extensions` header, and gives the handler the ones it named in
`ctx.extensions`.

## Using your MCP tools

To serve your tools as an A2A agent as they are, mount `Phantom.A2A.Bridge`:

```elixir
agent "tools", Phantom.A2A.Bridge, tools: ~w[search_studies create_question]
```

Its card lists each tool as a skill, and an extension with the tools' input
schemas. A client calls a tool with a message whose data part names it,
`{"tool": "search_studies", "arguments": {"query": "churn"}}`, and gets a
message with the tool's result. Messages that name no tool go to the
`:fallback` agent, if you give one.

When your router implements the MCP Tasks callbacks, a tool that answers with
a `Phantom.Tasks` becomes an A2A task: `GetTask`, `CancelTask`, and answers to
its input requests go to your router, and each
`Phantom.Tracker.notify_task_updated/1` reaches A2A clients waiting on it. See
`Phantom.A2A.Bridge`.

For an agent that decides what to do itself, call tools from its handler.
`Phantom.Router.call_tool/4` runs a tool with the session's assigns and
allow-lists, and waits for its result:

```elixir
def handle_message(message, ctx) do
  {:ok, %{content: [%{text: text} | _]}} =
    Phantom.Router.call_tool(ctx.session, :search_studies, query: query_from(message))

  {:reply, Phantom.A2A.Message.agent(text), ctx}
end
```

## Calling other agents

`Phantom.A2A.Client` calls any A2A agent, Phantom's or not, over JSON-RPC or
HTTP+JSON. Add the optional `{:req, "~> 0.5"}` dependency, then:

```elixir
alias Phantom.A2A.Client

{:ok, client} = Client.new("https://agents.example", headers: [{"authorization", "Bearer " <> token}])

{:ok, task} = Client.send_message(client, "Review study 42", return_immediately: true)

{:ok, stream} = Client.subscribe(client, task.id)
Enum.each(stream, &IO.inspect/1)
```

`Client.new/2` fetches the card and picks a binding it lists. The client
refuses to stream, use push notifications, or fetch an extended card when the
card doesn't advertise them.

## Listing your agents

A2A has no method to list an agent's peers, so clients find agents by their
cards. To build a directory page or a test of your own agents, use
`c:Phantom.Router.list_agents/2`. By default it lists every `agent` route
without path params the session may use; override it to add the agents your
routes with path params resolve.

## Testing

`Phantom.A2A.Test` sends requests through `Phantom.A2A.Plug` in the test
process, so `connect/2` and validation run, and returns the decoded JSON:

```elixir
import Phantom.A2A.Test

test "answers with a task" do
  assert {:task, %{"status" => %{"state" => "TASK_STATE_SUBMITTED"}}} =
           send_message(MyApp.MCP.Router, "research", "Review study 42",
             headers: [{"authorization", "Bearer " <> token}]
           )
end
```

Phantom itself runs the official A2A conformance suite (ACTS) in CI against a
test agent; see `test/acts/README.md` in the repository.

## Telemetry

Each request is a `[:phantom, :a2a, :dispatch]` span, and each push
delivery a `[:phantom, :a2a, :push]` span. The dispatch metadata carries the
W3C trace context the client sent in its `traceparent`, `tracestate`, and
`baggage` headers, for your tracer. See `Phantom.A2A.Plug` and
`Phantom.A2A.Push` for the metadata.

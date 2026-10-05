# Tasks

The [Tasks extension](https://modelcontextprotocol.io/specification/2026-07-28/extensions/tasks)
(`io.modelcontextprotocol/tasks`) lets a tool answer `tools/call` with a task
instead of a result. The client polls the task with `tasks/get` until it
finishes, answers its input requests with `tasks/update`, and may cancel it
with `tasks/cancel`. Tasks require MCP `2026-07-28`.

Phantom handles the protocol. You store the tasks, run the work, and move
each task through its statuses:

| Phantom | You |
|---|---|
| Builds `CreateTaskResult` and `tasks/get` responses from `Phantom.Tasks` | Generate unguessable task IDs (`Phantom.Tasks.generate_id/0`) |
| Advertises the extension and rejects clients that did not declare it | Store a task *before* returning it, so an immediate `tasks/get` finds it |
| Validates the `Mcp-Name` routing header on `tasks/*` | Check access in `c:Phantom.Router.get_task/2` |
| Passes only outstanding `inputResponses` to `c:Phantom.Router.update_task/3` | Never reuse an input request key during a task's lifetime |
| Sends `notifications/tasks` to `subscriptions/listen` streams | Call `Phantom.Tracker.notify_task_updated/1` with the task or its ID after each change |
| | Delete tasks after their TTL |

## Returning a task

A tool returns a `Phantom.Tasks` struct like any other result. Only answer
with a task when the client declared the extension on this request.
Otherwise, do the work in a process, report progress, and respond when it
finishes:

```elixir
def export_report(%{"report_id" => report_id} = params, session) do
  if Phantom.Session.tasks_supported?(session) do
    {:reply, start_export(params, session), session}
  else
    Task.async(fn ->
      csv =
        Reports.export!(report_id,
          on_progress: &Phantom.Session.notify_progress(session, &1, &2, "Exporting")
        )

      Phantom.Session.respond(session, Tool.text(csv))
    end)

    {:noreply, session}
  end
end
```

If a tool returns a task anyway, Phantom answers with the `-32021` missing
capability error. A tool that only works as a task can return that error itself,
before creating anything:

```elixir
{:error, Phantom.Request.missing_task_capability(), session}
```

## Router callbacks

Implementing `c:Phantom.Router.get_task/2` enables the extension:

- `c:Phantom.Router.get_task/2` — fetch a task for `tasks/get`, `tasks/update`,
  and `tasks/cancel`. Return `{:error, :not_found}` when the session may not
  see it, so the client cannot tell whether it exists.
- `c:Phantom.Router.update_task/3` — receive answers to the task's
  `input_requests`. Without it, Phantom acknowledges `tasks/update` and drops
  the answers.
- `c:Phantom.Router.cancel_task/2` — cancel the work. Without it, Phantom
  acknowledges `tasks/cancel` and the task carries on, which the spec allows.
- `c:Phantom.Router.authorize_task_subscriptions/2` — which tasks a
  `subscriptions/listen` stream may follow. Defaults to the tasks
  `get_task/2` returns; override it to check many with one query. Before each
  notification, the stream fetches the task with `get_task/2`, which checks
  access again and sends the stored task.

## Example: Ecto and Oban

This example stores tasks in Postgres and runs them with
[Oban](https://hexdocs.pm/oban). Inserting the task and its job in one
transaction means a task never exists without its job, or the reverse.

### Migration

```elixir
defmodule MyApp.Repo.Migrations.CreateMCPTasks do
  use Ecto.Migration

  def change do
    create table(:mcp_tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :status_message, :string
      add :input_requests, :map, null: false, default: %{}
      add :input_responses, :map, null: false, default: %{}
      add :result, :map
      add :error, :map
      add :job_id, :bigint
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:mcp_tasks, [:user_id])
    create index(:mcp_tasks, [:expires_at])
  end
end
```

### Schema and context

```elixir
defmodule MyApp.MCP.TaskRecord do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "mcp_tasks" do
    belongs_to :user, MyApp.Accounts.User
    field :status, Ecto.Enum, values: [:working, :input_required, :completed, :failed, :cancelled]
    field :status_message, :string
    field :input_requests, :map, default: %{}
    field :input_responses, :map, default: %{}
    field :result, :map
    field :error, :map
    field :job_id, :integer
    field :expires_at, :utc_datetime_usec

    timestamps()
  end
end
```

```elixir
defmodule MyApp.MCP.TaskRecords do
  import Ecto.Query

  alias MyApp.MCP.TaskRecord
  alias MyApp.Repo

  @ttl :timer.hours(6)

  def create!(user, attrs \\ %{}) do
    now = DateTime.utc_now()

    %TaskRecord{
      id: Phantom.Tasks.generate_id(),
      user_id: user.id,
      status: :working,
      expires_at: DateTime.add(now, @ttl, :millisecond)
    }
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  def get(id, user), do: Repo.get_by(TaskRecord, id: id, user_id: user.id)
  def get!(id), do: Repo.get!(TaskRecord, id)

  def to_phantom(%TaskRecord{} = record) do
    Phantom.Tasks.new(
      id: record.id,
      status: record.status,
      status_message: record.status_message,
      created_at: record.inserted_at,
      last_updated_at: record.updated_at,
      ttl_ms: DateTime.diff(record.expires_at, record.inserted_at, :millisecond),
      poll_interval_ms: 2_000,
      input_requests: record.input_requests,
      result: record.result,
      error: record.error
    )
  end

  def working(id, message), do: transition(id, fn _ -> %{status: :working, status_message: message} end)

  def complete(id, result),
    do: transition(id, fn _ -> %{status: :completed, result: result, input_requests: %{}} end)

  def fail(id, error),
    do: transition(id, fn _ -> %{status: :failed, error: error, input_requests: %{}} end)

  def cancel(id),
    do: transition(id, fn _ -> %{status: :cancelled, status_message: "Cancelled"} end)

  def need_input(id, requests),
    do: transition(id, fn _ -> %{status: :input_required, input_requests: requests} end)

  # Answered requests are removed; the task works again once none remain.
  def answer(id, responses) do
    transition(id, fn record ->
      remaining = Map.drop(record.input_requests, Map.keys(responses))

      %{
        status: if(remaining == %{}, do: :working, else: :input_required),
        input_requests: remaining,
        input_responses: Map.merge(record.input_responses, responses)
      }
    end)
  end

  # Only a running task changes. A finished task stays finished, so a job
  # that completes after the client cancelled leaves it cancelled.
  defp transition(id, fun) do
    result =
      Repo.transact(fn ->
        query =
          from t in TaskRecord,
            where: t.id == ^id and t.status in [:working, :input_required],
            lock: "FOR UPDATE"

        case Repo.one(query) do
          nil -> {:error, :finished}
          record -> record |> Ecto.Changeset.change(fun.(record)) |> Repo.update()
        end
      end)

    with {:ok, record} <- result do
      Phantom.Tracker.notify_task_updated(to_phantom(record))
    end

    result
  end

  def prune do
    Repo.delete_all(from t in TaskRecord, where: t.expires_at < ^DateTime.utc_now())
  end
end
```

`Repo.transact/2` requires Ecto 3.13. Use `Repo.transaction/1` on older versions.

### The tool and its job

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router, name: "MyApp", vsn: "1.0"

  alias MyApp.MCP.TaskRecords

  @description "Export a report as CSV. Large reports run as a task."
  tool :export_report do
    field :report_id, :integer, required: true
  end

  def export_report(%{"report_id" => report_id}, session) do
    if Phantom.Session.tasks_supported?(session) do
      {:ok, record} =
        MyApp.Repo.transact(fn ->
          record = TaskRecords.create!(session.assigns.current_user)
          job = Oban.insert!(MyApp.ExportWorker.new(%{task_id: record.id, report_id: report_id}))
          {:ok, MyApp.Repo.update!(Ecto.Changeset.change(record, job_id: job.id))}
        end)

      {:reply, TaskRecords.to_phantom(record), session}
    else
      Task.async(fn ->
        csv =
          MyApp.Reports.export!(report_id,
            on_progress: &Phantom.Session.notify_progress(session, &1, &2, "Exporting")
          )

        Phantom.Session.respond(session, Tool.text(csv))
      end)

      {:noreply, session}
    end
  end

  def get_task(id, session) do
    case TaskRecords.get(id, session.assigns.current_user) do
      nil -> {:error, :not_found}
      record -> {:ok, TaskRecords.to_phantom(record)}
    end
  end

  # Once every request is answered, run the job that asked for input again.
  def update_task(task, responses, _session) do
    case TaskRecords.answer(task.id, responses) do
      {:ok, %{status: :working, job_id: job_id}} -> Oban.retry_job(job_id)
      _ -> :ok
    end
  end

  def cancel_task(task, _session) do
    with {:ok, record} <- TaskRecords.cancel(task.id), do: Oban.cancel_job(record.job_id)
    :ok
  end
end
```

The worker reports through the context. A tool error is still a `completed`
task with `isError: true`; `failed` is only for JSON-RPC errors.

```elixir
defmodule MyApp.ExportWorker do
  use Oban.Worker, queue: :exports, max_attempts: 3

  alias MyApp.MCP.TaskRecords
  alias Phantom.Tool

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => id, "report_id" => report_id}}) do
    TaskRecords.working(id, "Rendering report #{report_id}")

    case MyApp.Reports.export(report_id) do
      {:ok, csv} ->
        TaskRecords.complete(id, Tool.response(Tool.text(csv)))
        :ok

      {:error, :too_large} ->
        TaskRecords.complete(id, Tool.error("The report is too large"))
        :ok

      # Oban retries the job; the task stays working meanwhile.
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

A job that crashes on its last attempt would leave its task `working` until
its TTL. Fail the task from Oban's telemetry instead:

```elixir
# In your application's start/2
:telemetry.attach("mcp-task-failures", [:oban, :job, :exception], &MyApp.MCP.TaskTelemetry.handle_exception/4, nil)
```

```elixir
defmodule MyApp.MCP.TaskTelemetry do
  alias MyApp.MCP.TaskRecords

  def handle_exception(_event, _measure, %{job: %{args: %{"task_id" => id}} = job} = meta, _config)
      when meta.state == :discard or job.attempt >= job.max_attempts do
    TaskRecords.fail(id, Phantom.Request.internal_error("The task stopped unexpectedly"))
  end

  def handle_exception(_event, _measure, _meta, _config), do: :ok
end
```

Prune expired tasks with Oban's cron plugin:

```elixir
config :my_app, Oban,
  plugins: [{Oban.Plugins.Cron, crontab: [{"@hourly", MyApp.PruneMCPTasksWorker}]}]
```

```elixir
defmodule MyApp.PruneMCPTasksWorker do
  use Oban.Worker, queue: :maintenance

  @impl Oban.Worker
  def perform(_job) do
    MyApp.MCP.TaskRecords.prune()
    :ok
  end
end
```

### Asking for input during a task

A task in `input_required` lists its requests, and the client answers them
with `tasks/update`. Each key must be new for the task's lifetime. The
`update_task/3` callback above stores the answers and retries the job once
none are outstanding, so the job reads them from the record. Here, a job for
an `export_all` tool confirms first:

```elixir
def perform(%Oban.Job{args: %{"task_id" => id}}) do
  record = TaskRecords.get!(id)

  case record.input_responses do
    %{"confirm" => %{"action" => "accept"}} ->
      TaskRecords.complete(id, Tool.response(Tool.text(MyApp.Reports.export_all!())))

    %{"confirm" => _declined} ->
      TaskRecords.complete(id, Tool.response(Tool.text("Export skipped")))

    _ ->
      elicit =
        Phantom.Elicit.form(%{
          message: "Export every report? This may take a while.",
          requested_schema: [%{name: "confirm", type: :boolean, required: true}]
        })

      TaskRecords.need_input(id, %{"confirm" => Phantom.Elicit.to_input_request(elicit)})
  end

  :ok
end
```

## Example: Oban Pro

With [Oban Pro](https://oban.pro), a worker hook can fail the task when the
job is discarded, in place of the telemetry handler. `after_process/3` runs
for `:complete`, `:cancel`, `:discard`, `:error`, and `:snooze`;
`c:Phantom.Router.cancel_task/2` already records cancellations:

```elixir
defmodule MyApp.ExportWorker do
  use Oban.Pro.Worker, queue: :exports, max_attempts: 3

  alias MyApp.MCP.TaskRecords
  alias Phantom.Tool

  @impl Oban.Pro.Worker
  def process(%Oban.Job{args: %{"report_id" => report_id} = args}) do
    mark_working(args, "Rendering report #{report_id}")
    progress = &Phantom.Session.notify_progress(args["progress"], &1, &2, "Exporting")

    with {:ok, csv} <- MyApp.Reports.export(report_id, on_progress: progress) do
      complete(args, csv)
      {:ok, csv}
    end
  end

  @impl Oban.Pro.Worker
  def after_process(:discard, %{args: %{"task_id" => id}}, _result),
    do: TaskRecords.fail(id, Phantom.Request.internal_error("The export failed"))

  def after_process(_state, _job, _result), do: :ok

  defp mark_working(%{"task_id" => id}, message), do: TaskRecords.working(id, message)
  defp mark_working(_args, _message), do: :ok

  defp complete(%{"task_id" => id}, csv), do: TaskRecords.complete(id, Tool.response(Tool.text(csv)))
  defp complete(_args, _csv), do: :ok
end
```

The worker returns `{:ok, csv}`, so the same job also serves clients without
tasks. [`Oban.Pro.Relay`](https://oban.pro/docs/pro/Oban.Pro.Relay.html)
inserts it and awaits its result from any node, and the tool responds when it
arrives. `Phantom.Session.progress_ref/1` lets the job report progress to the
waiting request from whichever node runs it; with no ref in the arguments,
`notify_progress/4` does nothing:

```elixir
alias Oban.Pro.Relay

def export_report(%{"report_id" => report_id}, session) do
  if Phantom.Session.tasks_supported?(session) do
    # ...insert the task and the job, as above
  else
    Task.async(fn ->
      response =
        %{report_id: report_id, progress: Phantom.Session.progress_ref(session)}
        |> MyApp.ExportWorker.new()
        |> Relay.async()
        |> Relay.await(timeout: :timer.minutes(5))
        |> case do
          {:ok, csv} -> Tool.text(csv)
          {:error, :timeout} -> Tool.error("The export took too long")
          _failed -> Tool.error("The export failed")
        end

      Phantom.Session.respond(session, response)
    end)

    {:noreply, session}
  end
end
```

Relay needs a working PubSub notifier, and the Postgres notifier limits
results to 8kb compressed; use the `PG` notifier for larger results.

A [workflow](https://oban.pro/docs/pro/Oban.Pro.Workflow.html) splits the
task into steps. Each step reports its progress as the status message, and
the last step builds the result from the steps' recorded output:

```elixir
alias Oban.Pro.Workflow

def export_report(%{"report_id" => report_id}, session) do
  {:ok, record} =
    MyApp.Repo.transact(fn ->
      record = TaskRecords.create!(session.assigns.current_user)
      args = %{task_id: record.id, report_id: report_id}

      Workflow.new()
      |> Workflow.add(:fetch, MyApp.FetchWorker.new(args))
      |> Workflow.add(:render, MyApp.RenderWorker.new(args), deps: :fetch)
      |> Workflow.add(:finish, MyApp.FinishWorker.new(args), deps: :render)
      |> Oban.insert_all()

      {:ok, record}
    end)

  {:reply, TaskRecords.to_phantom(record), session}
end
```

Each step that the next one reads must be recorded. `MyApp.FetchWorker`
uses `recorded: true` and returns `{:ok, rows}` the same way.

```elixir
defmodule MyApp.RenderWorker do
  use Oban.Pro.Worker, queue: :exports, recorded: true

  @impl Oban.Pro.Worker
  def process(%Oban.Job{args: %{"task_id" => id}} = job) do
    TaskRecords.working(id, "Rendering")
    rows = Workflow.get_recorded(job, :fetch)
    {:ok, MyApp.Reports.to_csv(rows)}
  end
end

defmodule MyApp.FinishWorker do
  use Oban.Pro.Worker, queue: :exports

  @impl Oban.Pro.Worker
  def process(%Oban.Job{args: %{"task_id" => id}} = job) do
    csv = Workflow.get_recorded(job, :render)
    TaskRecords.complete(id, Phantom.Tool.response(Phantom.Tool.text(csv)))
    :ok
  end
end
```

To cancel a workflow, cancel its jobs in `c:Phantom.Router.cancel_task/2`
with `Workflow.cancel_jobs/3`.

## Testing

`Phantom.Test` sends task requests with the extension declared. Build the
session with the stateless protocol. With Oban's `testing: :inline`, jobs run
inside `Oban.insert/2`, so the task is finished by the time the tool replies:

```elixir
setup do
  Phantom.Test.start(router: MyApp.MCP.Router)
  user = insert(:user)
  {:ok, session: build_session(MyApp.MCP.Router, protocol_version: "2026-07-28", assigns: %{current_user: user})}
end

test "exports a report as a task", %{session: session} do
  %{taskId: id} =
    session
    |> call_tool(:export_report, %{report_id: 1}, tasks: true)
    |> assert_task(status: :working)

  session
  |> get_task(id)
  |> assert_task(status: :completed)
end
```

Use `update_task/4` and `cancel_task/3` for the other methods.

## Load balancers

Clients send the task ID in the `Mcp-Name` header on `tasks/get`,
`tasks/update`, and `tasks/cancel`, and Phantom rejects a mismatch. When tasks
live in a shared database, any node can answer them. When they live in one
node's memory, route on `Mcp-Name`.

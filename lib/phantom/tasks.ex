defmodule Phantom.Tasks do
  @moduledoc """
  A task from the MCP Tasks extension (`io.modelcontextprotocol/tasks`),
  available under MCP `2026-07-28`.

  A tool handler may answer a call with a task instead of a result, and the
  client polls for the outcome. Return one from the handler and Phantom
  responds with a `CreateTaskResult`:

      def export_report(params, session) do
        task = MyApp.MCPTasks.create!(session, params)
        {:reply, Phantom.Tasks.new(id: task.id, status: :working, created_at: task.inserted_at), session}
      end

  Phantom does not store tasks. You store them, run the work, and move them
  through their statuses; Phantom asks your router for them when the client
  polls. Check `Phantom.Session.tasks_supported?/1` before returning a task,
  since a client that did not declare the extension cannot receive one.

  Return the task from the handler. `Phantom.Session.respond/2` does not
  accept one, since the task is already the asynchronous answer. Only tools
  answer with tasks.

  ## Fields

    - `:id` - (required) The task ID. It acts as a bearer token, so it must be
      unguessable; see `generate_id/0`.
    - `:status` - (required) One of `:working`, `:input_required`,
      `:completed`, `:failed`, or `:cancelled`. Strings are accepted.
    - `:created_at` - (required) A `DateTime`.
    - `:last_updated_at` - A `DateTime`. Defaults to `:created_at`.
    - `:status_message` - An optional message describing the current status.
    - `:ttl_ms` - Milliseconds from creation that the task is kept, or `nil`
      for unlimited.
    - `:poll_interval_ms` - Suggested milliseconds between client polls.
    - `:input_requests` - Required when `:input_required`. A map of keys to
      `Phantom.Elicit` structs or embedded request maps. Keys must not be
      reused over the task's lifetime.
    - `:result` - Required when `:completed`. The final `CallToolResult`, such
      as `Phantom.Tool.response(Phantom.Tool.text("Done"))`. A tool error is
      still `:completed`.
    - `:error` - Required when `:failed`. A JSON-RPC error with `:code` and
      `:message`, such as `Phantom.Request.internal_error("Timed out")`.
  """

  @statuses ~w[working input_required completed failed cancelled]a
  @status_strings Map.new(@statuses, &{Atom.to_string(&1), &1})

  @enforce_keys [:id, :status, :created_at, :last_updated_at]
  defstruct [
    :id,
    :status,
    :status_message,
    :created_at,
    :last_updated_at,
    :ttl_ms,
    :poll_interval_ms,
    :result,
    :error,
    input_requests: %{}
  ]

  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          status_message: String.t() | nil,
          created_at: DateTime.t(),
          last_updated_at: DateTime.t(),
          ttl_ms: non_neg_integer() | nil,
          poll_interval_ms: pos_integer() | nil,
          input_requests: %{String.t() => map()},
          result: map() | nil,
          error: map() | nil
        }

  @doc """
  Build a task. Raises `ArgumentError` when the fields do not describe a
  valid task for its status.
  """
  @spec new(map() | Keyword.t()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      id: fetch_id!(attrs),
      status: fetch_status!(attrs),
      created_at: fetch_datetime!(attrs, :created_at),
      last_updated_at: fetch_datetime!(attrs, :last_updated_at, attrs[:created_at]),
      status_message: attrs[:status_message],
      ttl_ms: fetch_duration!(attrs, :ttl_ms, 0),
      poll_interval_ms: fetch_duration!(attrs, :poll_interval_ms, 1),
      input_requests: Map.new(attrs[:input_requests] || %{}, &to_input_request/1),
      result: attrs[:result],
      error: attrs[:error]
    }
    |> validate_status_fields!()
  end

  @doc false
  def extension, do: "io.modelcontextprotocol/tasks"

  @doc "Generate an unguessable, URL-safe task ID with 256 bits of entropy."
  @spec generate_id() :: String.t()
  def generate_id do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # Tasks changed with struct update syntax are validated as they leave Phantom.
  @doc false
  def to_json(%__MODULE__{} = task) do
    task = revalidate(task)
    task |> base_json() |> put_status_fields(task)
  end

  # The client fetches the result, error, and input requests with `tasks/get`.
  @doc false
  def to_create_result(%__MODULE__{} = task),
    do: task |> revalidate() |> base_json() |> Map.put(:resultType, "task")

  defp revalidate(task), do: task |> Map.from_struct() |> new()

  defp base_json(task) do
    %{
      taskId: task.id,
      status: Atom.to_string(task.status),
      createdAt: DateTime.to_iso8601(task.created_at),
      lastUpdatedAt: DateTime.to_iso8601(task.last_updated_at),
      ttlMs: task.ttl_ms
    }
    |> maybe_put(:statusMessage, task.status_message)
    |> maybe_put(:pollIntervalMs, task.poll_interval_ms)
  end

  defp put_status_fields(json, %{status: :input_required} = task),
    do: Map.put(json, :inputRequests, task.input_requests)

  defp put_status_fields(json, %{status: :completed} = task),
    do: Map.put(json, :result, task.result)

  defp put_status_fields(json, %{status: :failed} = task),
    do: Map.put(json, :error, task.error)

  defp put_status_fields(json, _task), do: json

  defp fetch_id!(%{id: id}) when is_binary(id) and byte_size(id) > 0, do: id

  defp fetch_id!(attrs),
    do: raise(ArgumentError, ":id must be a non-empty string, got: #{inspect(attrs[:id])}")

  defp fetch_status!(%{status: status}) when status in @statuses, do: status

  defp fetch_status!(%{status: status}) when is_map_key(@status_strings, status),
    do: Map.fetch!(@status_strings, status)

  defp fetch_status!(attrs) do
    raise ArgumentError,
          "status must be one of #{inspect(@statuses)}, got: #{inspect(attrs[:status])}"
  end

  defp fetch_datetime!(attrs, key, default \\ nil) do
    case attrs[key] || default do
      %DateTime{} = datetime -> datetime
      other -> raise ArgumentError, "#{inspect(key)} must be a DateTime, got: #{inspect(other)}"
    end
  end

  defp fetch_duration!(attrs, key, min) do
    case attrs[key] do
      nil ->
        nil

      ms when is_integer(ms) and ms >= min ->
        ms

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be nil or an integer >= #{min}, got: #{inspect(other)}"
    end
  end

  # Keys are strings, as the client's `inputResponses` keys are.
  defp to_input_request({key, %Phantom.Elicit{} = elicit}),
    do: {to_string(key), Phantom.Elicit.to_input_request(elicit)}

  defp to_input_request({key, request}), do: {to_string(key), request}

  defp validate_status_fields!(%{status: :completed, result: result})
       when not is_map(result),
       do: raise(ArgumentError, "a completed task requires a :result map")

  defp validate_status_fields!(%{status: :failed, error: %{code: code, message: message}} = task)
       when is_integer(code) and is_binary(message),
       do: task

  defp validate_status_fields!(
         %{status: :failed, error: %{"code" => code, "message" => message}} = task
       )
       when is_integer(code) and is_binary(message),
       do: task

  defp validate_status_fields!(%{status: :failed}),
    do: raise(ArgumentError, "a failed task requires an :error with a :code and :message")

  defp validate_status_fields!(%{status: :input_required, input_requests: requests})
       when map_size(requests) == 0,
       do: raise(ArgumentError, "an input_required task requires :input_requests")

  defp validate_status_fields!(task), do: task

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

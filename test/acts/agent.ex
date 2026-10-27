defmodule Phantom.ACTS.Agent do
  @moduledoc """
  The agent the A2A conformance suite (ACTS) tests. The first message of a
  task starts with a `tck-*` prefix that names the outcome the suite expects;
  see `sut-behaviors.yaml` and the ACTS SDK integration guide.
  """

  use Phantom.A2A.Agent,
    name: "Phantom ACTS agent",
    description: "Implements the ACTS tck-* behaviors",
    input_modes: ~w[text/plain application/json],
    output_modes: ~w[text/plain application/json]

  alias Phantom.A2A.{Artifact, Message, Part, Task, TaskStatus}
  alias Phantom.ACTS.Store

  @description "Produces the outcome a tck-* message names"
  skill :tck, tags: ["conformance"], examples: ["tck-complete-task hello"]

  @long_running_ms 1_000
  @chunks ["chunk one ", "chunk two ", "chunk three"]

  def handle_message(%Message{task_id: nil} = message, ctx) do
    case behavior(message) do
      "tck-message-response" -> {:reply, Message.agent("Direct message response"), ctx}
      behavior -> {:reply, start(behavior, ctx), ctx}
    end
  end

  # Continuations carry no prefix; the task's first message names the behavior.
  def handle_message(%Message{} = message, ctx) do
    {:ok, task} = Store.get(message.task_id)
    task = %{task | history: task.history ++ [message]}

    task =
      case {behavior(hd(task.history)), text(message)} do
        {"tck-multi-turn", "done" <> _} -> finish(task, :completed, "Multi-turn complete")
        {"tck-multi-turn", _text} -> finish(task, :input_required, "Send more, or done")
        {_behavior, _text} -> finish(task, :completed, "Done")
      end

    Store.put(task)
    {:reply, task, ctx}
  end

  defp start(behavior, ctx) do
    task = Task.submitted(ctx)

    task =
      case behavior do
        "tck-complete-task" -> finish(task, :completed, "Task completed")
        "tck-input-required" -> finish(task, :input_required, "More input required")
        "tck-multi-turn" -> finish(task, :input_required, "Send more, or done")
        "tck-auth-required" -> finish(task, :auth_required, "Bearer credentials required")
        "tck-reject-task" -> finish(task, :rejected, "Task rejected")
        "tck-task-failure" -> finish(task, :failed, "Task failed: simulated error")
        "tck-cancel" -> finish(task, :working, "Working until canceled")
        "tck-long-running" -> task
        "tck-stream-basic" -> task
        "tck-stream-chunked" -> task
        "tck-artifact-" <> kind -> complete_with(task, artifact(kind))
        unknown -> finish(task, :failed, "Unknown behavior #{inspect(unknown)}")
      end

    Store.put(task)
    run(behavior, ctx.task_ref)
    task
  end

  defp run("tck-long-running", ref) do
    spawn(fn ->
      Store.emit(ref, Task.status(:working, "Working"))
      Process.sleep(@long_running_ms)
      Store.emit(ref, Task.status(:completed, "Long-running task completed"))
    end)
  end

  defp run("tck-stream-basic", ref) do
    spawn(fn ->
      Store.emit(ref, Task.status(:working))

      Store.emit(
        ref,
        Artifact.update("stream", [Part.text("streamed content")], last_chunk: true)
      )

      Store.emit(ref, Task.status(:completed, "Stream complete"))
    end)
  end

  defp run("tck-stream-chunked", ref) do
    spawn(fn ->
      Store.emit(ref, Task.status(:working))

      for {chunk, i} <- Enum.with_index(@chunks) do
        Store.emit(
          ref,
          Artifact.update("chunked", [Part.text(chunk)],
            append: i > 0,
            last_chunk: i == length(@chunks) - 1
          )
        )
      end

      Store.emit(ref, Task.status(:completed, "Stream complete"))
    end)
  end

  defp run(_behavior, _ref), do: :ok

  defp artifact("text"), do: Artifact.new("text", [Part.text("generated text content")])
  defp artifact("data"), do: Artifact.new("data", [Part.data(%{"key" => "value", "count" => 1})])

  defp artifact("file-url") do
    Artifact.new("file", [
      Part.url("https://example.com/document.txt",
        filename: "document.txt",
        media_type: "text/plain"
      )
    ])
  end

  defp artifact("file") do
    Artifact.new("file", [
      Part.raw("file content", filename: "document.txt", media_type: "text/plain")
    ])
  end

  defp complete_with(task, artifact),
    do: finish(%{task | artifacts: [artifact]}, :completed, "Task completed")

  defp finish(task, state, text) do
    %{
      task
      | status: %TaskStatus{
          state: state,
          message: Message.agent(text, task_id: task.id, context_id: task.context_id),
          timestamp: DateTime.utc_now()
        }
    }
  end

  defp behavior(message) do
    case Regex.run(~r/\Atck-[a-z0-9-]+/, text(message)) do
      [behavior] -> behavior
      nil -> "tck-complete-task"
    end
  end

  defp text(%Message{parts: [%Part{text: text} | _]}) when is_binary(text), do: String.trim(text)
  defp text(_message), do: ""

  def get_task(task_id, _ctx) do
    case Store.get(task_id) do
      {:ok, task} -> {:ok, task}
      :error -> {:error, :not_found}
    end
  end

  def cancel_task(%Task{} = task, ctx) do
    Store.emit(ctx.task_ref, Task.status(:canceled, "Canceled"))
    Store.get(task.id)
  end

  def list_tasks(filter, _ctx) do
    tasks =
      Store.all()
      |> Enum.filter(&(is_nil(filter.context_id) or &1.context_id == filter.context_id))
      |> Enum.filter(&(is_nil(filter.status) or &1.status.state == filter.status))
      |> Enum.filter(
        &(is_nil(filter.status_timestamp_after) or
            DateTime.compare(&1.status.timestamp, filter.status_timestamp_after) != :lt)
      )
      |> Enum.sort_by(& &1.status.timestamp, {:desc, DateTime})

    offset = String.to_integer(filter.page_token || "0")
    page = Enum.slice(tasks, offset, filter.page_size)
    next = offset + filter.page_size

    {:ok,
     %{
       tasks: page,
       next_page_token: if(next < length(tasks), do: Integer.to_string(next)),
       total_size: length(tasks)
     }}
  end
end

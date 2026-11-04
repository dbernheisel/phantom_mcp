defmodule Phantom.A2A.Task do
  @moduledoc """
  A unit of work an A2A agent tracks for a client.

  Phantom doesn't store tasks. The agent stores them, returns them from
  `c:Phantom.A2A.Agent.handle_message/2` and `c:Phantom.A2A.Agent.get_task/2`,
  and reports progress with `Phantom.A2A.publish/2`:

      def handle_message(message, ctx) do
        {:ok, _job} = MyApp.Reviews.start(ctx.task_ref, message)
        {:reply, Phantom.A2A.Task.submitted(ctx), ctx}
      end

      # Later, wherever the work runs:
      Phantom.A2A.publish(task_ref, Phantom.A2A.Task.status(:working, "Reading study…"))
  """

  import Phantom.Utils, only: [remove_nils: 1]

  alias Phantom.A2A.{Artifact, Context, Message, Part, StatusUpdate, TaskStatus}

  @enforce_keys [:id, :status]
  defstruct [:id, :context_id, :status, :metadata, artifacts: [], history: [], sequence: 0]

  @type t :: %__MODULE__{
          id: String.t(),
          context_id: String.t(),
          status: TaskStatus.t(),
          metadata: map() | nil,
          artifacts: [Artifact.t()],
          history: [Message.t()],
          sequence: non_neg_integer()
        }

  @doc """
  A new task for the request in `ctx`, in the `submitted` state, with the
  client's message as its history. `opts` sets other fields.
  """
  def submitted(%Context{} = ctx, opts \\ []) do
    struct!(
      __MODULE__,
      [
        id: ctx.task_ref.task_id,
        context_id: ctx.context_id,
        status: %TaskStatus{state: :submitted, timestamp: DateTime.utc_now()},
        history: [ctx.message]
      ] ++ opts
    )
  end

  @doc """
  An event that moves a task to `state`. `message` is text or a
  `Phantom.A2A.Message` from the agent, such as the question for
  `:input_required`.

  ## Options

    * `:metadata` - metadata for the event
  """
  def status(state, message \\ nil, opts \\ []) when state in unquote(TaskStatus.states()) do
    message = if is_binary(message), do: Message.agent(message), else: message

    %StatusUpdate{
      status: %TaskStatus{state: state, message: message, timestamp: DateTime.utc_now()},
      metadata: opts[:metadata]
    }
  end

  @doc false
  def from_json(%{"id" => id, "status" => status} = json) when is_binary(id) do
    with {:ok, context_id} <- context_id(json["contextId"]),
         {:ok, status} <- TaskStatus.from_json(status),
         {:ok, artifacts} <- Part.list_from_json(json["artifacts"] || [], &Artifact.from_json/1),
         {:ok, history} <- Part.list_from_json(json["history"] || [], &Message.from_json/1) do
      {:ok,
       %__MODULE__{
         id: id,
         context_id: context_id,
         status: status,
         metadata: json["metadata"],
         artifacts: artifacts,
         history: history
       }}
    end
  end

  def from_json(_json), do: {:error, "task needs an id and a status"}

  defp context_id(id) when is_binary(id) or is_nil(id), do: {:ok, id}
  defp context_id(_id), do: {:error, "task contextId must be a string"}

  @doc false
  def to_json(%__MODULE__{} = task, opts \\ []) do
    remove_nils(%{
      "id" => task.id,
      "contextId" => task.context_id,
      "status" => TaskStatus.to_json(task.status, task.id, task.context_id),
      "metadata" => task.metadata,
      "artifacts" => artifacts_json(task.artifacts, Keyword.get(opts, :include_artifacts, true)),
      "history" => history_json(trim_history(task.history, opts[:history_length]))
    })
  end

  defp artifacts_json([], _include?), do: nil
  defp artifacts_json(_artifacts, false), do: nil
  defp artifacts_json(artifacts, true), do: Enum.map(artifacts, &Artifact.to_json/1)

  defp history_json([]), do: nil
  defp history_json(history), do: Enum.map(history, &Message.to_json/1)

  defp trim_history(history, nil), do: history
  defp trim_history(_history, length) when length <= 0, do: []
  defp trim_history(history, length), do: Enum.take(history, -length)
end

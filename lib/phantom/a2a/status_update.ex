defmodule Phantom.A2A.StatusUpdate do
  @moduledoc """
  An event that changes a task's status. Build one with
  `Phantom.A2A.Task.status/3` and send it with `Phantom.A2A.publish/2`.
  """

  import Phantom.Utils, only: [remove_nils: 1]

  alias Phantom.A2A.TaskStatus

  @enforce_keys [:status]
  defstruct [:task_id, :context_id, :status, :metadata, :sequence]

  @type t :: %__MODULE__{
          task_id: String.t() | nil,
          context_id: String.t() | nil,
          status: TaskStatus.t(),
          metadata: map() | nil,
          sequence: pos_integer() | nil
        }

  @doc false
  def to_json(%__MODULE__{} = update) do
    remove_nils(%{
      "taskId" => update.task_id,
      "contextId" => update.context_id,
      "status" => TaskStatus.to_json(update.status),
      "metadata" => update.metadata
    })
  end
end

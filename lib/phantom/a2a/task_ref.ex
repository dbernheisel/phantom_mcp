defmodule Phantom.A2A.TaskRef do
  @moduledoc """
  Addresses an A2A task for `Phantom.A2A.publish/2`.

  Pass it to wherever the task's work runs. To store it, such as in an Oban
  job's args, use `encode/1` and `decode/1`.
  """

  @enforce_keys [:router, :agent_id, :task_id]
  defstruct [:pubsub, :router, :agent_id, :task_id]

  @type t :: %__MODULE__{
          pubsub: atom() | nil,
          router: module(),
          agent_id: String.t(),
          task_id: String.t()
        }

  @doc "Encode as a string"
  def encode(%__MODULE__{} = ref) do
    JSON.encode!([
      Atom.to_string(ref.pubsub),
      Atom.to_string(ref.router),
      ref.agent_id,
      ref.task_id
    ])
  end

  @doc "Decode a string from `encode/1`. Only atoms that already exist are accepted."
  def decode(encoded) when is_binary(encoded) do
    with {:ok, [pubsub, router, agent_id, task_id]} <- JSON.decode(encoded) do
      {:ok,
       %__MODULE__{
         pubsub: String.to_existing_atom(pubsub),
         router: String.to_existing_atom(router),
         agent_id: agent_id,
         task_id: task_id
       }}
    else
      _ -> {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end
end

defmodule Phantom.A2A.TaskStatus do
  @moduledoc "The state of an A2A task, with an optional message from the agent."

  import Phantom.Utils, only: [remove_nils: 1]

  alias Phantom.A2A.Message

  @enforce_keys [:state]
  defstruct [:state, :message, :timestamp]

  @type state ::
          :submitted
          | :working
          | :input_required
          | :auth_required
          | :completed
          | :failed
          | :canceled
          | :rejected

  @type t :: %__MODULE__{
          state: state(),
          message: Message.t() | nil,
          timestamp: DateTime.t() | nil
        }

  @states ~w[submitted working input_required auth_required completed failed canceled rejected]a

  @doc false
  def states, do: @states

  @doc false
  def state_from_json("TASK_STATE_" <> name) do
    case Enum.find(@states, &(Atom.to_string(&1) == String.downcase(name))) do
      nil -> :error
      state -> {:ok, state}
    end
  end

  def state_from_json(_json), do: :error

  @doc false
  def from_json(%{"state" => state} = json) do
    with {:ok, state} <- state_from_json(state),
         {:ok, message} <- optional(json["message"], &Message.from_json/1),
         {:ok, timestamp} <- timestamp(json["timestamp"]) do
      {:ok, %__MODULE__{state: state, message: message, timestamp: timestamp}}
    else
      :error -> {:error, "unknown task state #{inspect(state)}"}
      error -> error
    end
  end

  def from_json(_json), do: {:error, "task status needs a state"}

  defp optional(nil, _decode), do: {:ok, nil}
  defp optional(json, decode), do: decode.(json)

  defp timestamp(nil), do: {:ok, nil}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _error -> {:error, "invalid timestamp #{inspect(value)}"}
    end
  end

  defp timestamp(value), do: {:error, "invalid timestamp #{inspect(value)}"}

  @doc false
  # A status message names its task and context, unless it already does.
  def to_json(%__MODULE__{state: state} = status, task_id \\ nil, context_id \\ nil)
      when state in @states do
    remove_nils(%{
      "state" => "TASK_STATE_" <> String.upcase(Atom.to_string(state)),
      "message" => message_json(status.message, task_id, context_id),
      "timestamp" => status.timestamp && DateTime.to_iso8601(status.timestamp)
    })
  end

  defp message_json(nil, _task_id, _context_id), do: nil

  defp message_json(%Message{} = message, task_id, context_id) do
    Message.to_json(%{
      message
      | task_id: message.task_id || task_id,
        context_id: message.context_id || context_id
    })
  end
end

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

  defp timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _error -> {:error, "invalid timestamp #{inspect(value)}"}
    end
  end

  @doc false
  def to_json(%__MODULE__{state: state} = status) when state in @states do
    remove_nils(%{
      "state" => "TASK_STATE_" <> String.upcase(Atom.to_string(state)),
      "message" => status.message && Message.to_json(status.message),
      "timestamp" => status.timestamp && DateTime.to_iso8601(status.timestamp)
    })
  end
end

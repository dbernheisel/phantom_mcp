defmodule Phantom.A2A.Message do
  @moduledoc """
  A message between a client and an A2A agent.

  An agent handler can answer `SendMessage` with a message instead of a
  task, when there is no work to track:

      def handle_message(_message, ctx), do: {:reply, Phantom.A2A.Message.agent("pong"), ctx}
  """

  import Phantom.Utils, only: [remove_nils: 1]

  alias Phantom.A2A.Part

  @enforce_keys [:message_id, :role]
  defstruct [
    :message_id,
    :role,
    :context_id,
    :task_id,
    :metadata,
    parts: [],
    extensions: [],
    reference_task_ids: []
  ]

  @type role :: :user | :agent
  @type t :: %__MODULE__{
          message_id: String.t(),
          role: role(),
          context_id: String.t() | nil,
          task_id: String.t() | nil,
          metadata: map() | nil,
          parts: [Part.t()],
          extensions: [String.t()],
          reference_task_ids: [String.t()]
        }

  @roles %{"ROLE_USER" => :user, "ROLE_AGENT" => :agent}

  @doc """
  A message from the agent. Give it text, or a list of `Phantom.A2A.Part`.
  `opts` sets other fields, such as `:metadata`.
  """
  def agent(text_or_parts, opts \\ []), do: build(:agent, text_or_parts, opts)

  @doc "A message from the user. Useful in tests."
  def user(text_or_parts, opts \\ []), do: build(:user, text_or_parts, opts)

  defp build(role, text, opts) when is_binary(text), do: build(role, [Part.text(text)], opts)

  defp build(role, parts, opts) when is_list(parts) do
    struct!(__MODULE__, [message_id: UUIDv7.generate(), role: role, parts: parts] ++ opts)
  end

  @doc false
  def from_json(%{"messageId" => id, "role" => role, "parts" => [_ | _] = parts} = json)
      when is_binary(id) and is_map_key(@roles, role) do
    with :ok <- check_fields(json),
         {:ok, parts} <- Part.list_from_json(parts) do
      {:ok,
       %__MODULE__{
         message_id: id,
         role: Map.fetch!(@roles, role),
         context_id: json["contextId"],
         task_id: json["taskId"],
         metadata: json["metadata"],
         parts: parts,
         extensions: json["extensions"] || [],
         reference_task_ids: json["referenceTaskIds"] || []
       }}
    end
  end

  def from_json(_json), do: {:error, "message must have a messageId, a role, and parts"}

  defp check_fields(json) do
    valid? =
      optional?(json["contextId"], &is_binary/1) and optional?(json["taskId"], &is_binary/1) and
        optional?(json["metadata"], &is_map/1) and optional?(json["extensions"], &is_list/1) and
        optional?(json["referenceTaskIds"], &is_list/1)

    if valid?, do: :ok, else: {:error, "message has a field of the wrong type"}
  end

  defp optional?(value, valid?), do: is_nil(value) or valid?.(value)

  @doc false
  def to_json(%__MODULE__{} = message) do
    remove_nils(%{
      "messageId" => message.message_id,
      "role" => if(message.role == :user, do: "ROLE_USER", else: "ROLE_AGENT"),
      "contextId" => message.context_id,
      "taskId" => message.task_id,
      "metadata" => message.metadata,
      "parts" => Enum.map(message.parts, &Part.to_json/1),
      "extensions" => non_empty(message.extensions),
      "referenceTaskIds" => non_empty(message.reference_task_ids)
    })
  end

  defp non_empty([]), do: nil
  defp non_empty(list), do: list
end

defmodule Phantom.A2A.Error do
  @moduledoc """
  A2A protocol errors. An agent handler can return one:

      {:error, Phantom.A2A.Error.unsupported_operation("Exports are disabled"), ctx}
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message]

  @type t :: %__MODULE__{code: integer(), message: String.t()}

  @reasons %{
    -32001 => "TASK_NOT_FOUND",
    -32002 => "TASK_NOT_CANCELABLE",
    -32003 => "PUSH_NOTIFICATION_NOT_SUPPORTED",
    -32004 => "UNSUPPORTED_OPERATION",
    -32005 => "CONTENT_TYPE_NOT_SUPPORTED",
    -32006 => "INVALID_AGENT_RESPONSE",
    -32007 => "EXTENDED_AGENT_CARD_NOT_CONFIGURED",
    -32008 => "EXTENSION_SUPPORT_REQUIRED",
    -32009 => "VERSION_NOT_SUPPORTED",
    -32700 => "PARSE_ERROR",
    -32600 => "INVALID_REQUEST",
    -32601 => "METHOD_NOT_FOUND",
    -32602 => "INVALID_PARAMS"
  }

  def task_not_found(task_id), do: new(-32001, "Task not found: #{task_id}")
  def push_config_not_found(id), do: new(-32001, "Push notification config not found: #{id}")
  def task_not_cancelable(task_id), do: new(-32002, "Task cannot be canceled: #{task_id}")
  def push_notification_not_supported, do: new(-32003, "Push notifications are not supported")
  def unsupported_operation(message), do: new(-32004, message)
  def content_type_not_supported, do: new(-32005, "Content type not supported")
  def invalid_agent_response, do: new(-32006, "Invalid agent response")
  def extended_card_not_configured, do: new(-32007, "Extended agent card not configured")
  def extension_support_required(uri), do: new(-32008, "Extension support required: #{uri}")
  def version_not_supported(version), do: new(-32009, "A2A version not supported: #{version}")
  def parse_error, do: new(-32700, "Parse error")
  def invalid_request(message \\ "Invalid request"), do: new(-32600, message)
  def method_not_found(method), do: new(-32601, "Method not found: #{method}")
  def invalid_params(message), do: new(-32602, message)
  def internal_error, do: new(-32603, "Internal error")

  defp new(code, message), do: %__MODULE__{code: code, message: message}

  @http_statuses %{
    -32001 => 404,
    -32002 => 400,
    -32003 => 400,
    -32004 => 400,
    -32005 => 400,
    -32007 => 400,
    -32008 => 400,
    -32009 => 400,
    -32700 => 400,
    -32600 => 400,
    -32601 => 501,
    -32602 => 400
  }

  @grpc_statuses %{
    -32001 => "NOT_FOUND",
    -32601 => "UNIMPLEMENTED",
    -32002 => "FAILED_PRECONDITION",
    -32003 => "FAILED_PRECONDITION",
    -32004 => "FAILED_PRECONDITION",
    -32007 => "FAILED_PRECONDITION",
    -32008 => "FAILED_PRECONDITION",
    -32009 => "FAILED_PRECONDITION",
    -32005 => "INVALID_ARGUMENT",
    -32700 => "INVALID_ARGUMENT",
    -32600 => "INVALID_ARGUMENT",
    -32602 => "INVALID_ARGUMENT"
  }

  @grpc_by_http %{
    400 => "INVALID_ARGUMENT",
    401 => "UNAUTHENTICATED",
    403 => "PERMISSION_DENIED",
    404 => "NOT_FOUND",
    405 => "UNIMPLEMENTED",
    413 => "INVALID_ARGUMENT",
    501 => "UNIMPLEMENTED"
  }

  @doc false
  # An error a server sent: a JSON-RPC error, or the `error` of a
  # `google.rpc.Status`, whose `ErrorInfo` reason names the A2A error.
  def from_json(%{"code" => code, "message" => message})
      when is_integer(code) and code < 0 and is_binary(message),
      do: new(code, message)

  def from_json(%{"message" => message} = json) when is_binary(message) do
    reason = Enum.find_value(List.wrap(json["details"]), &(is_map(&1) && &1["reason"]))
    code = Enum.find_value(@reasons, -32603, fn {code, name} -> name == reason && code end)
    new(code, message)
  end

  def from_json(_json), do: invalid_agent_response()

  @doc false
  # The HTTP status of an error on the HTTP+JSON binding.
  def http_status(%__MODULE__{code: code}), do: Map.get(@http_statuses, code, 500)

  @doc false
  # A `google.rpc.Status` body for the HTTP+JSON binding. An explicit HTTP
  # status, such as 401 from `connect/2`, decides the gRPC status.
  def to_status_json(%__MODULE__{} = error, http_status) do
    status =
      if http_status == http_status(error),
        do: Map.get(@grpc_statuses, error.code, "INTERNAL"),
        else: Map.get(@grpc_by_http, http_status, "INTERNAL")

    %{
      "error" => %{
        "code" => http_status,
        "status" => status,
        "message" => error.message,
        "details" => to_json(error)["data"]
      }
    }
  end

  @doc false
  def to_json(%__MODULE__{} = error) do
    %{
      "code" => error.code,
      "message" => error.message,
      "data" => [
        %{
          "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
          "reason" => Map.get(@reasons, error.code, "INTERNAL_ERROR"),
          "domain" => "a2a-protocol.org",
          "metadata" => %{"timestamp" => DateTime.to_iso8601(DateTime.utc_now())}
        }
      ]
    }
  end
end

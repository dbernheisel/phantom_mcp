defmodule Phantom.ErrorWrapper do
  @moduledoc """
  Wraps errors that occur during a request or batch or requests.
  This allows the connection to finish, and then reraises with this error
  containing the exceptions by request.
  """

  defexception [:message, :exceptions_by_request]

  def new(message, exceptions_by_request) do
    %__MODULE__{
      exceptions_by_request: exceptions_by_request,
      message:
        message <>
          "\n\n" <>
          Enum.map_join(exceptions_by_request, "\n\n", fn {request, exception, stacktrace} ->
            exception = unwrap_plug_wrapper(exception)

            """
            Error:
            #{inspect(exception)}

            Request:
            #{inspect(request)}

            Stacktrace:
            #{Exception.format_stacktrace(stacktrace)}
            """
          end)
    }
  end

  defp unwrap_plug_wrapper(%Plug.Conn.WrapperError{} = error) do
    Exception.normalize(error.kind, error.reason, error.stack)
  end

  defp unwrap_plug_wrapper(error), do: error
end

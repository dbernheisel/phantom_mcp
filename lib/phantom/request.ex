defmodule Phantom.Request do
  @moduledoc false
  defstruct [:id, :type, :method, :params, :response, :spec]

  @connection -32000
  @resource_not_found -32002
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603
  @parse_error -32700

  import Phantom.Utils
  alias Phantom.Session

  def invalid(message \\ nil) do
    %{code: @invalid_request, message: message || "Invalid request"}
  end

  def parse_error(message \\ nil) do
    %{code: @parse_error, message: message || "Parsing error"}
  end

  def closed(message \\ nil) do
    %{code: @connection, message: message || "Connection closed"}
  end

  def internal_error(message \\ nil) do
    %{code: @internal_error, message: message || "Internal server error"}
  end

  def not_found(message \\ nil),
    do: %{code: @method_not_found, message: message || "Method not found"}

  def resource_not_found(data),
    do: %{code: @resource_not_found, data: data, message: "Resource not found"}

  def invalid_params(data), do: %{code: @invalid_params, message: "Invalid Params", data: data}
  def invalid_params, do: %{code: @invalid_params, message: "Invalid Params"}

  def build(nil), do: nil

  def build(%{"jsonrpc" => "2.0", "method" => method} = request)
      when is_binary(method) do
    {:ok,
     struct!(__MODULE__,
       params: request["params"] || %{},
       method: method,
       id: request["id"]
     )}
  end

  def build(request) do
    {:error, struct!(__MODULE__, id: request["id"], response: error(request["id"], invalid()))}
  end

  def ping() do
    %{jsonrpc: "2.0", method: "ping", id: UUIDv7.generate()}
  end

  def empty() do
    %{jsonrpc: "2.0", result: ""}
  end

  def result(%__MODULE__{} = request, type, result) do
    %{request | type: type, response: %{id: request.id, jsonrpc: "2.0", result: result}}
  end

  def error(id \\ nil, error) do
    %{jsonrpc: "2.0", error: error, id: id}
  end

  @doc false
  def completion_response({:reply, results, session}, _session) do
    {:reply, completion_response(results), session}
  end

  def completion_response({:error, error}, session) do
    {:error, error, session}
  end

  def completion_response({:noreply, session}, _session) do
    {:noreply, session}
  end

  def completion_response(results) when is_list(results) do
    %{
      completion: %{
        values: Enum.take(List.wrap(results), 100),
        hasMore: length(results) > 100
      }
    }
  end

  def completion_response(%{} = results) do
    %{
      completion:
        remove_nils(%{
          values: Enum.take(List.wrap(results[:values]), 100),
          total: results[:total],
          hasMore: results[:has_more] || false
        })
    }
  end

  def resource_response({:error, reason}, _uri, session) do
    {:error, reason, session}
  end

  def resource_response({:noreply, _} = result, _uri, _session), do: result

  def resource_response({:error, _reason, %Session{}} = result, _uri, _session) do
    result
  end

  def resource_response(nil, uri, session) do
    {:error, resource_not_found(%{uri: uri}), session}
  end

  def resource_response({:reply, nil, %Session{} = session}, uri, _session) do
    {:error, resource_not_found(%{uri: uri}), session}
  end

  def resource_response({:reply, results, %Session{} = session}, _uri, _session) do
    {:reply, Phantom.Resource.response(results), session}
  end

  def resource_updated(content) do
    %{jsonrpc: "2.0", method: "notifications/resources/updated", params: content}
  end

  def notify(content) do
    %{jsonrpc: "2.0", method: "notifications/message", params: content}
  end

  def notify_progress(progress_token, progress, total) do
    %{
      jsonrpc: "2.0",
      method: "notifications/progress",
      params:
        remove_nils(%{
          progressToken: progress_token,
          progress: progress,
          total: total
        })
    }
  end
end

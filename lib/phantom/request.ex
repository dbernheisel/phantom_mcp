defmodule Phantom.Request do
  @moduledoc false
  defstruct [:id, :type, :method, :params, :response]

  @connection -32000
  @resource_not_found -32002
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603
  @parse_error -32700

  import Phantom.Utils

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

  def empty(%__MODULE__{} = request, type) do
    %{request | type: type, response: ""}
  end

  def result(%__MODULE__{} = request, type, result) do
    %{request | type: type, response: %{id: request.id, jsonrpc: "2.0", result: result}}
  end

  def error(id \\ nil, error) do
    %{jsonrpc: "2.0", error: error, id: id}
    # if id, do: Map.put(body, :id, id), else: body
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

  @doc false
  def tool_response({:reply, results, session}, _session) do
    {:reply, Phantom.Tool.call_response(results), session}
  end

  def tool_response({:error, reason}, session), do: {:error, reason, session}
  def tool_response(other, _session), do: other

  @doc false
  def prompt_response({:reply, results, session}, prompt, _session) do
    {:reply, Phantom.Prompt.call_response(results, prompt), session}
  end

  def prompt_response({:error, error}, _prompt, session), do: {:error, error, session}
  def prompt_response(other, _prompt, _session), do: other

  def resource_response(nil, uri, _resource_template, session) do
    {:error, resource_not_found(%{uri: uri}), session}
  end

  def resource_response({:error, reason}, _uri, _resource_template, session) do
    {:error, reason, session}
  end

  def resource_response({:reply, results, session}, uri, resource_template, _session) do
    {:reply, Phantom.ResourceTemplate.read_response(results, resource_template, uri), session}
  end

  def resource_response(other, _uri, _session), do: other

  def notify(content) do
    %{jsonrpc: "2.0", method: "notifications/message", params: content}
  end
end

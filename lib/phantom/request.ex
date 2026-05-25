defmodule Phantom.Request do
  @moduledoc "Standard requests and responses for the MCP protocol"
  defstruct [:id, :type, :method, :params, :response, :spec, meta: %{}]

  @opaque t :: %__MODULE__{
            id: String.t(),
            type: String.t(),
            method: String.t(),
            params: map(),
            response: map(),
            spec: Phantom.ResourceTemplate.t() | Phantom.Tool.t() | Phantom.Prompt.t(),
            meta: map()
          }

  @connection -32000
  @resource_not_found -32002
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603
  @parse_error -32700
  @url_elicitation_required -32042

  import Phantom.Utils
  alias Phantom.Session

  @doc "Invalid request"
  def invalid(message \\ nil) do
    %{code: @invalid_request, message: message || "Invalid request"}
  end

  @doc "Duplicate JSON-RPC request id for a session"
  def duplicate_request,
    do: %{code: @invalid_request, message: "Duplicate request id for session"}

  @doc "Invalid request due to bad parameters"
  def invalid_params(data), do: %{code: @invalid_params, message: "Invalid Params", data: data}
  def invalid_params, do: %{code: @invalid_params, message: "Invalid Params"}

  @doc "Invalid request due to parsing error"
  def parse_error(message \\ nil) do
    %{code: @parse_error, message: message || "Parsing error"}
  end

  @doc "Invalid request due to no streaming connection being available"
  def closed(message \\ nil) do
    %{code: @connection, message: message || "Connection closed"}
  end

  @doc "Server encountered an issue"
  def internal_error(message \\ nil) do
    %{code: @internal_error, message: message || "Internal server error"}
  end

  @doc "The method is not implemented or found"
  def not_found(message \\ nil),
    do: %{code: @method_not_found, message: message || "Method not found"}

  @doc "The resource is not found"
  def resource_not_found(data),
    do: %{code: @resource_not_found, data: data, message: "Resource not found"}

  @doc "Error indicating URL mode elicitation is required before retrying"
  def url_elicitation_required(elicitations) when is_list(elicitations) do
    %{
      code: @url_elicitation_required,
      message: "This request requires more information.",
      data: %{elicitations: Enum.map(elicitations, &Phantom.Elicit.to_json/1)}
    }
  end

  @doc "Elicitation complete notification"
  def elicitation_complete(elicitation_id) do
    %{
      jsonrpc: "2.0",
      method: "notifications/elicitation/complete",
      params: %{elicitationId: elicitation_id}
    }
  end

  @doc false
  def build(nil), do: nil

  def build(%{"jsonrpc" => "2.0", "method" => method} = request)
      when is_binary(method) do
    params = request["params"] || %{}

    {:ok,
     struct!(__MODULE__,
       params: params,
       method: method,
       id: request["id"],
       meta: params["_meta"] || %{}
     )}
  end

  def build(%{"jsonrpc" => "2.0", "result" => result} = response)
      when is_map(result) do
    {:ok,
     struct!(__MODULE__,
       response: result,
       id: response["id"]
     )}
  end

  def build(request) do
    {:error, struct!(__MODULE__, id: request["id"], response: error(request["id"], invalid()))}
  end

  @doc false
  def to_json(%__MODULE__{} = request) do
    %{
      "jsonrpc" => "2.0",
      "method" => request.method,
      "id" => request.id,
      "params" => request.params
    }
  end

  @doc false
  # Used by Phantom.Router.dispatch_method to populate the `:trace_context`
  # key on `[:phantom, :dispatch]` telemetry span metadata. Tracer libraries
  # (OpenTelemetry et al.) attach to that event and read the field directly;
  # devs shouldn't need to call this function.
  def trace_context(%__MODULE__{meta: meta}) when is_map(meta) do
    remove_nils(%{
      traceparent: meta["traceparent"],
      tracestate: meta["tracestate"],
      baggage: meta["baggage"]
    })
  end

  def trace_context(_), do: %{}

  @doc """
  Annotate a JSON-RPC result with MCP `2026-07-28` cache hints.

  These are *advisory* — the server doesn't cache; the hints tell the client
  (and any intermediate CDN / gateway) how to treat the result. Modeled on
  HTTP `Cache-Control`.

  Options:

  - `:ttl_ms` — how long the client may consider the result fresh, in milliseconds
    (becomes top-level `ttlMs` on the result)
  - `:scope` — `:public` (shareable across users) or `:private` (per-session);
    becomes top-level `cacheScope`

  Works on any result map — `tools/call`, `resources/read`, `prompts/get`,
  list responses, completions:

      Tool.text("...") |> Request.with_cache(ttl_ms: 60_000, scope: :public)

      Resource.list(links, nil) |> Request.with_cache(ttl_ms: 300_000, scope: :public)
  """
  def with_cache(%{} = result, opts) do
    result
    |> put_if_set(:ttlMs, Keyword.get(opts, :ttl_ms))
    |> put_if_set(:cacheScope, encode_scope(Keyword.get(opts, :scope)))
  end

  defp put_if_set(map, _key, nil), do: map
  defp put_if_set(map, key, value), do: Map.put(map, key, value)

  defp encode_scope(nil), do: nil
  defp encode_scope(:public), do: "public"
  defp encode_scope(:private), do: "private"

  @doc "Ping request"
  def ping() do
    %{jsonrpc: "2.0", method: "ping", id: UUIDv7.generate()}
  end

  @doc "An empty response"
  def empty() do
    %{jsonrpc: "2.0", result: ""}
  end

  @doc false
  def result(%__MODULE__{} = request, type, result) do
    %{request | type: type, response: %{id: request.id, jsonrpc: "2.0", result: result}}
  end

  @doc "Response error"
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

  @doc false
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

  def resource_response(
        {:reply, %{code: code, message: _} = error, %Session{} = session},
        _uri,
        _session
      )
      when is_integer(code) and code < 0 do
    {:error, error, session}
  end

  def resource_response({:reply, results, %Session{} = session}, _uri, _session) do
    response = Phantom.Resource.response(results)
    {:reply, maybe_add_ui_meta(response, session.request), session}
  end

  # Dynamic _meta from plug pipeline takes precedence
  defp maybe_add_ui_meta(%{_meta: _} = response, _request), do: response

  defp maybe_add_ui_meta(response, %{spec: %{meta: %{ui: %Phantom.UI{} = ui}}}) do
    case Phantom.UI.to_resource_meta(ui) do
      nil -> response
      meta -> Map.put(response, :_meta, meta)
    end
  end

  defp maybe_add_ui_meta(response, _), do: response

  @doc "Resource updated notification"
  def resource_updated(content) do
    %{jsonrpc: "2.0", method: "notifications/resources/updated", params: content}
  end

  @doc "Tools List updated notification"
  def tools_updated do
    %{jsonrpc: "2.0", method: "notifications/tools/list_changed"}
  end

  @doc "Prompts List updated notification"
  def prompts_updated do
    %{jsonrpc: "2.0", method: "notifications/prompts/list_changed"}
  end

  @doc "Resources List updated notification"
  def resources_updated do
    %{jsonrpc: "2.0", method: "notifications/resources/list_changed"}
  end

  @doc "A generic notifiation"
  def notify(content) do
    %{jsonrpc: "2.0", method: "notifications/message", params: content}
  end

  @doc "Progress notifiation"
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

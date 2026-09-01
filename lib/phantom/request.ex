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
  @header_mismatch -32020
  @missing_capability -32021
  @unsupported_protocol -32022
  @resource_not_found -32002
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603
  @parse_error -32700
  @url_elicitation_required -32042

  @protocol_version_meta_key "io.modelcontextprotocol/protocolVersion"
  @client_info_meta_key "io.modelcontextprotocol/clientInfo"
  @client_capabilities_meta_key "io.modelcontextprotocol/clientCapabilities"
  @log_level_meta_key "io.modelcontextprotocol/logLevel"

  @modern_protocol "2026-07-28"
  @supported_protocols ~w[2026-07-28]
  @modern_methods ~w[
    server/discover
    tools/list
    tools/call
    prompts/list
    prompts/get
    resources/list
    resources/templates/list
    resources/read
    completion/complete
    subscriptions/listen
    notifications/cancelled
  ]

  @modern_cacheable_methods ~w[
    server/discover
    tools/list
    prompts/list
    resources/list
    resources/templates/list
    resources/read
  ]

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

  @doc """
  The HTTP routing headers (`Mcp-Method`, `Mcp-Name`) do not match the
  request body, or a required header is missing (SEP-2243, MCP 2026-07-28).
  """
  def header_mismatch(message),
    do: %{code: @header_mismatch, message: message}

  @doc "A request omitted a client capability required to process it."
  def missing_capability(capabilities) do
    %{
      code: @missing_capability,
      message: "Missing required client capability",
      data: %{requiredCapabilities: List.wrap(capabilities)}
    }
  end

  @doc "The requested MCP protocol version is unsupported."
  def unsupported_protocol(requested) do
    %{
      code: @unsupported_protocol,
      message: "Unsupported protocol version",
      data: %{supported: @supported_protocols, requested: requested}
    }
  end

  @doc """
  The resource is not found.

  Under MCP `2026-07-28` (SEP-2164) the JSON-RPC code is the standard
  `-32602 Invalid Params`. Under earlier protocol versions it remains
  the MCP-custom `-32002` so legacy clients continue to match.
  """
  def resource_not_found(data, %Session{} = session) do
    code = if Session.stateless?(session), do: @invalid_params, else: @resource_not_found
    %{code: code, data: data, message: "Resource not found"}
  end

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

  def build(%{"jsonrpc" => "2.0", "method" => method} = request) when is_binary(method) do
    params = Map.get(request, "params", %{})

    if not is_map(params) or not valid_id?(request) do
      {:error, struct!(__MODULE__, id: request["id"], response: error(request["id"], invalid()))}
    else
      {:ok,
       struct!(__MODULE__,
         params: params,
         method: method,
         id: request["id"],
         meta: Map.get(params, "_meta", %{})
       )}
    end
  end

  def build(%{"jsonrpc" => "2.0", "method" => _method} = request) do
    {:error, struct!(__MODULE__, id: request["id"], response: error(request["id"], invalid()))}
  end

  def build(%{"jsonrpc" => "2.0", "result" => result} = response)
      when is_map(result) do
    {:ok,
     struct!(__MODULE__,
       response: result,
       id: response["id"]
     )}
  end

  def build(request) when is_map(request) do
    id = Map.get(request, "id")
    {:error, struct!(__MODULE__, id: id, response: error(id, invalid()))}
  end

  def build(_request),
    do: {:error, struct!(__MODULE__, id: nil, response: error(nil, invalid()))}

  defp valid_id?(request) do
    not Map.has_key?(request, "id") or is_binary(request["id"]) or is_integer(request["id"])
  end

  @doc false
  def protocol_version(%__MODULE__{meta: meta}), do: protocol_version(meta)

  def protocol_version(meta) when is_map(meta),
    do: meta[@protocol_version_meta_key] || meta["protocolVersion"]

  def protocol_version(_), do: nil

  @doc false
  def client_info(%__MODULE__{meta: meta}), do: client_info(meta)

  def client_info(meta) when is_map(meta),
    do: meta[@client_info_meta_key] || meta["clientInfo"]

  def client_info(_), do: nil

  @doc false
  def client_capabilities(%__MODULE__{meta: meta}), do: client_capabilities(meta)

  def client_capabilities(meta) when is_map(meta),
    do: meta[@client_capabilities_meta_key] || meta["capabilities"]

  def client_capabilities(_), do: nil

  @doc false
  def log_level(%__MODULE__{meta: meta}), do: log_level(meta)

  def log_level(meta) when is_map(meta), do: meta[@log_level_meta_key]
  def log_level(_), do: nil

  @doc false
  def modern?(%__MODULE__{} = request), do: protocol_version(request) == @modern_protocol
  def modern?(version), do: version == @modern_protocol

  @doc false
  def stateless_envelope?(%__MODULE__{meta: meta}) when is_map(meta),
    do:
      Map.has_key?(meta, @protocol_version_meta_key) or
        meta["protocolVersion"] == @modern_protocol

  def stateless_envelope?(_), do: false

  @doc false
  def modern_method?(method), do: method in @modern_methods

  @doc false
  def validate_modern(%__MODULE__{} = request, transport_version \\ nil) do
    body_version = if is_map(request.meta), do: request.meta[@protocol_version_meta_key]
    capabilities = if is_map(request.meta), do: request.meta[@client_capabilities_meta_key]
    log_level = if is_map(request.meta), do: request.meta[@log_level_meta_key]

    cond do
      not is_map(request.meta) ->
        {:error, invalid_params(%{field: "params._meta", reason: "must be an object"})}

      is_nil(body_version) ->
        {:error,
         invalid_params(%{
           field: "params._meta.#{@protocol_version_meta_key}",
           reason: "is required"
         })}

      body_version != @modern_protocol ->
        {:error, unsupported_protocol(body_version)}

      not is_nil(transport_version) and transport_version != body_version ->
        {:error,
         header_mismatch("Header mismatch: MCP-Protocol-Version does not match request metadata")}

      not is_map(capabilities) ->
        {:error,
         invalid_params(%{
           field: "params._meta.#{@client_capabilities_meta_key}",
           reason: "is required and must be an object"
         })}

      not modern_method?(request.method) ->
        {:error, not_found()}

      has_invalid_input_responses?(request.params) ->
        {:error, invalid_params(%{field: "params.inputResponses", reason: "must be an object"})}

      not valid_log_level?(log_level) ->
        {:error,
         invalid_params(%{
           field: "params._meta.#{@log_level_meta_key}",
           reason: "is not a valid logging level"
         })}

      true ->
        :ok
    end
  end

  defp has_invalid_input_responses?(%{"inputResponses" => value}), do: not is_map(value)
  defp has_invalid_input_responses?(_), do: false

  defp valid_log_level?(nil), do: true

  defp valid_log_level?(level) when is_binary(level),
    do: level in Enum.map(Phantom.ClientLogger.log_levels(), &Atom.to_string(elem(&1, 0)))

  defp valid_log_level?(_), do: false

  @doc false
  def normalize_result(%{} = result, %__MODULE__{} = request) do
    if protocol_version(request) == "2026-07-28" do
      result = normalize_result_type(result)

      if is_map_key(request.params, "inputResponses") or
           is_map_key(request.params, "requestState") do
        result
      else
        put_default_cache_hint(result, request.method)
      end
    else
      result
    end
  end

  @doc false
  def normalize_result(%{} = result, %__MODULE__{} = request, %Session{} = session) do
    result = normalize_result(result, request)

    if modern?(request) and is_atom(session.router) do
      case session.router.server_info(session) do
        {:ok, info} when is_map(info) ->
          meta = Map.get(result, :_meta) || Map.get(result, "_meta") || %{}
          meta = Map.put_new(meta, "io.modelcontextprotocol/serverInfo", info)

          result
          |> Map.delete("_meta")
          |> Map.put(:_meta, meta)

        _ ->
          result
      end
    else
      result
    end
  end

  defp normalize_result_type(%{resultType: "inputRequired"} = result),
    do: %{result | resultType: "input_required"}

  defp normalize_result_type(%{"resultType" => "inputRequired"} = result),
    do: %{result | "resultType" => "input_required"}

  defp normalize_result_type(%{resultType: _} = result), do: result
  defp normalize_result_type(%{"resultType" => _} = result), do: result
  defp normalize_result_type(result), do: Map.put(result, :resultType, "complete")

  defp put_default_cache_hint(%{resultType: "input_required"} = result, _method), do: result

  defp put_default_cache_hint(%{"resultType" => "input_required"} = result, _method),
    do: result

  defp put_default_cache_hint(result, _method)
       when is_map_key(result, :requestState) or is_map_key(result, "requestState"),
       do: result

  defp put_default_cache_hint(result, method) when method in @modern_cacheable_methods do
    result
    |> put_new_result_field(:ttlMs, "ttlMs", 0)
    |> put_new_result_field(:cacheScope, "cacheScope", "private")
  end

  defp put_default_cache_hint(result, _method), do: result

  defp put_new_result_field(result, atom_key, string_key, value) do
    if Map.has_key?(result, atom_key) or Map.has_key?(result, string_key) do
      result
    else
      Map.put(result, atom_key, value)
    end
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
    ttl = Keyword.get(opts, :ttl_ms)
    scope = Keyword.get(opts, :scope)

    if not (is_nil(ttl) or (is_integer(ttl) and ttl >= 0)) do
      raise ArgumentError, ":ttl_ms must be a non-negative integer"
    end

    if scope not in [nil, :public, :private] do
      raise ArgumentError, ":scope must be :public or :private"
    end

    Map.merge(
      result,
      remove_nils(%{
        ttlMs: ttl,
        cacheScope: encode_scope(scope)
      })
    )
  end

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
    {:error, resource_not_found(%{uri: uri}, session), session}
  end

  def resource_response({:reply, nil, %Session{} = session}, uri, _session) do
    {:error, resource_not_found(%{uri: uri}, session), session}
  end

  def resource_response(
        {:reply, %{code: code, message: _} = error, %Session{} = session},
        _uri,
        _session
      )
      when is_integer(code) and code < 0 do
    {:error, error, session}
  end

  def resource_response(
        {:reply, %{resultType: type} = result, %Session{} = session},
        _uri,
        _original_session
      )
      when type in ["input_required", "inputRequired"],
      do: {:reply, result, session}

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

  @doc false
  def subscriptions_acknowledged(subscription_id, notifications) do
    %{
      jsonrpc: "2.0",
      method: "notifications/subscriptions/acknowledged",
      params: %{
        notifications: notifications,
        _meta: %{"io.modelcontextprotocol/subscriptionId" => subscription_id}
      }
    }
  end

  @doc false
  def subscription_cancelled(subscription_id, reason \\ "Subscription closed") do
    %{
      jsonrpc: "2.0",
      method: "notifications/cancelled",
      params: %{
        requestId: subscription_id,
        reason: reason,
        _meta: %{"io.modelcontextprotocol/subscriptionId" => subscription_id}
      }
    }
  end

  @doc "A generic notifiation"
  def notify(content) do
    %{jsonrpc: "2.0", method: "notifications/message", params: content}
  end

  @doc "Progress notifiation"
  def notify_progress(progress_token, progress, total, message \\ nil) do
    %{
      jsonrpc: "2.0",
      method: "notifications/progress",
      params:
        remove_nils(%{
          progressToken: progress_token,
          progress: progress,
          total: total,
          message: message
        })
    }
  end
end

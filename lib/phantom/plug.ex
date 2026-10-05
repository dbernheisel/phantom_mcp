defmodule Phantom.Plug do
  @default_opts [
    pubsub: nil,
    origins: ["http://localhost:4000"],
    validate_origin: true,
    validate_session: false,
    hosts: :all,
    session_timeout: :timer.seconds(30),
    max_request_size: 1_048_576
  ]

  @moduledoc """
  Main Plug implementation for MCP HTTP transport with SSE support.

  This module provides a complete MCP server implementation with:
  - JSON-RPC 2.0 message handling
  - Server-Sent Events (SSE) streaming (legacy protocols)
  - Stateless transactional request/response (MCP `2026-07-28`)
  - CORS handling and security features
  - Session management integration
  - Origin validation

  Legacy clients (`≤ 2025-11-25`) carry an `mcp-session-id` header and may
  hold a persistent `GET` SSE stream for server-initiated traffic. Stateless
  core clients (`2026-07-28`) send no session header — every `POST` is
  self-contained and any node behind a round-robin load balancer can serve
  the call. Both modes run from the same router; the protocol version on
  each request determines the dispatch path.

  <!-- tabs-open -->

  ### Phoenix

  ```elixir
  defmodule MyAppWeb.Router do
    use MyAppWeb, :router
    # ...

    pipeline :mcp do
      plug :accepts, ["json", "sse"]

      plug Plug.Parsers,
        parsers: [{:json, length: 1_000_000}],
        pass: ["application/json"],
        json_decoder: JSON
    end

    scope "/mcp" do
      pipe_through :mcp

      forward "/", Phantom.Plug,
        router: MyApp.MCPRouter,
        pubsub: MyApp.PubSub
    end
  end
  ```

  ### Plug.Router

  ```elixir
  defmodule MyAppWeb.Router do
    use Plug.Router

    plug :match

    plug Plug.Parsers,
        parsers: [{:json, length: 1_000_000}],
        pass: ["application/json"],
        json_decoder: JSON

    plug :dispatch

    forward "/mcp",
        to: Phantom.Plug,
        init_opts: [
          router: MyApp.MCP.Router,
          pubsub: MyApp.PubSub
        ]
  end
  ```

  <!-- tabs-close -->

  Here are the defaults:

  ```elixir
  #{inspect(@default_opts, pretty: true)}
  ```

  ## Local testing

  Most MCP clients support Streamable HTTP natively. Configure them to
  connect directly to your Phantom server:

  ```json
  {
    "mcpServers": {
      "my_app": {
        "type": "http",
        "url": "http://localhost:4000/mcp"
      }
    }
  }
  ```

  > #### Avoid `mcp-remote` and `mcp-proxy` {: .warning}
  >
  > Third-party proxies like `mcp-remote` and `mcp-proxy` can break MCP
  > features such as elicitation, resource subscriptions, and session
  > management. Connect directly over HTTP when possible.
  >
  > If your client only supports stdio, use `Phantom.Stdio` instead of
  > proxying HTTP through a stdio wrapper.

  For a direct stdio transport without HTTP, see `Phantom.Stdio`.

  ## Telemetry

  Telemetry is provided with these events:

  - `[:phantom, :plug, :request, :connect]` with meta: `~w[session router conn opts]a`
  - `[:phantom, :plug, :request, :disconnect]` with meta: `~w[session router conn]a`
  - `[:phantom, :plug, :request, :terminate]` with meta: `~w[session router conn]a`
  - `[:phantom, :plug, :request, :exception]` with meta: `~w[session router conn stacktrace request exception]a`
  """

  @behaviour Plug

  # HTTP statuses for JSON-RPC errors. A request rejected before dispatch
  # gets its code's status, or 400. A handler's error only changes the status
  # of a 2026-07-28 response when its code is listed.
  @error_http_statuses %{
    -32601 => 404,
    -32020 => 400,
    -32021 => 400,
    -32022 => 400
  }

  import Plug.Conn

  alias Phantom.Cache
  alias Phantom.Request
  alias Phantom.Session

  @type opts :: [
          router: module(),
          origins: [String.t()] | :all | mfa(),
          validate_origin: boolean(),
          validate_session: boolean(),
          hosts: [String.t()] | :all | mfa(),
          session_timeout: pos_integer(),
          max_request_size: pos_integer()
        ]

  @doc """
  Initializes the plug with the given options.

  ## Options

  - `:router` - The MCP router module (required)
  - `:origins` - List of allowed origins or `:all` (default: localhost)
  - `:validate_origin` - Whether to validate the Origin header (default: true). Requests
    without one are allowed: only browsers send it, and only browsers can be used for DNS
    rebinding.
  - `:validate_session` - Whether to answer `404 Not Found` to a request whose
    `mcp-session-id` this server did not issue in an `initialize` response, or that was
    terminated with `DELETE`, so the client initializes again (default: false). Phantom
    keeps that record in memory, so a restart forgets every session. Apps that persist
    sessions across restarts should leave this off and answer `{:not_found, message}` from
    `c:Phantom.Router.connect/2` instead.
  - `:hosts` - List of allowed hosts (from the `Host` header, without the port), `:all`, or an
    MFA called with the host prepended to its arguments (default: `:all`). A server bound to
    localhost should set `hosts: ["localhost", "127.0.0.1", "[::1]"]` to reject DNS
    rebinding requests that a browser sends with an attacker's `Host`.
  - `:session_timeout` - Session timeout in milliseconds (default: 30s)
  - `:max_request_size` - Maximum request size in bytes (default: 1MB)
  """
  def init(opts) do
    @default_opts
    |> Keyword.merge(opts)
    |> Map.new()
  end

  def call(conn, opts) do
    app_config = Map.new(Application.get_all_env(opts.router))
    config = Map.merge(opts, app_config)

    conn
    |> put_private(:phantom, %{
      router: config.router,
      session: nil,
      requests: %{},
      modern: not legacy_request?(conn)
    })
    |> validate_request(config)
    |> validate_protocol_request()
    |> cors_preflight(config)
    |> cors_headers(config)
    |> connect(config)
    |> dispatch(config)
  end

  defp connect(conn, opts) do
    router = opts[:router]
    if not Cache.initialized?(router), do: Cache.register(router)

    session_id =
      if conn.private.phantom.modern,
        do: nil,
        else: get_req_header(conn, "mcp-session-id") |> List.first()

    session =
      Session.new(session_id,
        pubsub: opts.pubsub,
        transport_pid: conn.owner,
        pid: self(),
        router: router
      )

    try do
      case session |> router.connect(conn) |> validate_session(conn, opts) do
        {:ok, session} ->
          session = inherit_session_meta(session)

          :telemetry.execute(
            [:phantom, :plug, :request, :connect],
            %{},
            %{
              session: session,
              router: router,
              opts: opts,
              conn: conn
            }
          )

          put_in(conn.private.phantom.session, session)

        {unauthorized, www_authenticate}
        when unauthorized in [401, :unauthorized] and
               (is_map(www_authenticate) or is_binary(www_authenticate)) ->
          www_authenticate =
            if is_map(www_authenticate),
              do: www_authenticate(www_authenticate),
              else: www_authenticate

          conn
          |> put_status(401)
          |> put_resp_header("www-authenticate", www_authenticate)
          |> request_error(Request.closed("Unauthorized"))

        {forbidden, message}
        when forbidden in [403, :forbidden] and is_binary(message) ->
          conn |> put_status(403) |> request_error(Request.closed(message))

        {not_found, message}
        when not_found in [404, :not_found] and is_binary(message) ->
          conn |> put_status(404) |> request_error(Request.closed(message))

        {:error, error} when is_map(error) ->
          request_error(conn, error |> JSON.encode!() |> Request.closed())

        {:error, reason} ->
          request_error(conn, Request.closed("Connection failed: #{reason}"))
      end
    rescue
      e ->
        :telemetry.execute(
          [:phantom, :plug, :request, :exception],
          %{},
          %{conn: conn, stacktrace: __STACKTRACE__, exception: e}
        )

        json_error(conn, Request.internal_error())
        reraise(e, __STACKTRACE__)
    end
  end

  # A session id the server did not issue (or terminated) is answered with
  # 404 so the client initializes again. `initialize` itself starts a session,
  # and requests without a session id are not checked.
  defp validate_session({:ok, session} = result, conn, %{validate_session: true} = opts) do
    session_id = get_req_header(conn, "mcp-session-id") |> List.first()

    cond do
      is_nil(session_id) or conn.private.phantom.modern -> result
      conn.body_params["method"] == "initialize" -> result
      known_session?(session.id, opts.pubsub) -> result
      true -> {:not_found, "Session not found"}
    end
  end

  defp validate_session(result, _conn, _opts), do: result

  # Without the table (an escript), sessions cannot be told apart. With a
  # pubsub, another node's `initialize` may not have replicated here yet.
  defp known_session?(session_id, pubsub, retries \\ 5) do
    cond do
      not Phantom.SessionMeta.available?() ->
        true

      Phantom.SessionMeta.get(session_id) ->
        true

      is_nil(pubsub) or retries == 0 ->
        false

      true ->
        Process.sleep(20)
        known_session?(session_id, pubsub, retries - 1)
    end
  end

  defp validate_request(conn, opts) do
    cond do
      not valid_host?(conn.host, opts[:hosts]) ->
        conn
        |> put_status(403)
        |> request_error(Request.closed("Host not allowed"))

      opts[:validate_origin] && not valid_origin?(get_origin(conn), opts) ->
        conn
        |> put_status(403)
        |> request_error(Request.closed("Origin not allowed"))

      reported_content_length_exceeded?(conn, opts) ->
        conn
        |> put_status(413)
        |> request_error(Request.invalid("Request too large"))

      conn.method not in ~w[DELETE GET OPTIONS POST] ->
        conn
        |> put_status(405)
        |> request_error(Request.not_found("Method not allowed"))

      not supported_protocol_version?(conn) ->
        conn
        |> put_status(400)
        |> request_error(
          Request.invalid("Unsupported protocol version")
          |> Map.put(:data, %{
            supported: Request.supported_protocols(),
            requested: mcp_header(conn, "mcp-protocol-version")
          })
        )

      conn.method == "GET" and not accepts_event_stream?(conn) ->
        conn
        |> put_status(406)
        |> request_error(Request.invalid("Accept header must include text/event-stream"))

      conn.method not in ~w[DELETE GET OPTIONS] and map_size(conn.body_params) == 0 ->
        conn
        |> put_status(400)
        |> request_error(Request.parse_error("Parse error: Invalid JSON"))

      conn.body_params["_json"] == [] ->
        conn
        |> put_status(400)
        |> request_error(Request.parse_error("No requests"))

      true ->
        conn
    end
  end

  defp client_response?(params),
    do:
      (is_map_key(params, "result") or is_map_key(params, "error")) and
        not is_map_key(params, "method")

  # Clients before 2025-06-18 do not send the header, so its absence is allowed.
  # `validate_protocol_request/1` checks the version of a 2026-07-28 request.
  defp supported_protocol_version?(%Plug.Conn{private: %{phantom: %{modern: true}}}), do: true

  defp supported_protocol_version?(conn) do
    case mcp_header(conn, "mcp-protocol-version") do
      nil -> true
      version -> version in Request.supported_protocols()
    end
  end

  # A missing Accept header means the client accepts any media type.
  defp accepts_event_stream?(conn) do
    case get_req_header(conn, "accept") do
      [] ->
        true

      accept ->
        ranges = accept |> Enum.flat_map(&String.split(&1, ",")) |> Enum.map(&media_range/1)

        # The most specific matching range decides, and q=0 refuses it (RFC 9110 §12.5.1).
        case Enum.find_value(~w[text/event-stream text/* */*], &List.keyfind(ranges, &1, 0)) do
          {_type, q} -> q > 0
          nil -> false
        end
    end
  end

  defp media_range(range) do
    [type | params] =
      range |> String.split(";") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    {type, Enum.find_value(params, 1.0, &quality/1)}
  end

  defp quality("q=" <> value) do
    case Float.parse(value) do
      {q, ""} -> q
      _invalid -> 1.0
    end
  end

  defp quality(_param), do: nil

  defp validate_protocol_request(%Plug.Conn{halted: true} = conn), do: conn

  defp validate_protocol_request(%Plug.Conn{method: "POST"} = conn) do
    version = mcp_header(conn, "mcp-protocol-version")

    cond do
      not conn.private.phantom.modern ->
        conn

      match?(%{"_json" => _}, conn.body_params) ->
        protocol_error(conn, nil, Request.invalid("Batch requests are not supported"))

      not is_map(conn.body_params) ->
        protocol_error(conn, nil, Request.invalid())

      client_response?(conn.body_params) ->
        protocol_error(conn, conn.body_params["id"], Request.invalid())

      is_nil(version) ->
        protocol_error(
          conn,
          conn.body_params["id"],
          Request.header_mismatch("Missing required header: MCP-Protocol-Version")
        )

      true ->
        case Request.build(conn.body_params) do
          {:ok, request} ->
            case Request.validate(request, version) do
              :ok -> conn
              {:error, error} -> protocol_error(conn, request.id, error)
            end

          {:error, error} ->
            protocol_error(conn, error.id, error.response.error)
        end
    end
  end

  defp validate_protocol_request(conn), do: conn

  defp protocol_error(conn, id, %{code: code} = error) do
    conn
    |> put_status(Map.get(@error_http_statuses, code, 400))
    |> json_error(Request.error(id, error))
  end

  defp request_error(conn, error), do: json_error(conn, Request.error(error))

  defp dispatch(%Plug.Conn{halted: true} = conn, _opts), do: conn

  defp dispatch(
         %Plug.Conn{body_params: %Plug.Conn.Unfetched{}, method: "POST"} = conn,
         _opts
       ) do
    conn
    |> put_status(500)
    |> json_error(Request.error(Request.internal_error()))

    raise """
    #{inspect(__MODULE__)} encounted unfetched body parameters, usually meaning
    that the router does not have a body parser before it, such as `Plug.Parsers`.
    """
  end

  defp dispatch(%Plug.Conn{method: "GET"} = conn, opts) do
    if opts.pubsub do
      case maybe_track_session_stream(conn) do
        %Plug.Conn{halted: true} = conn ->
          conn

        conn ->
          session = conn.private.phantom.session

          conn
          |> put_resp_header("mcp-session-id", session.id)
          |> put_resp_header("cache-control", "no-cache, no-transform")
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)
          |> stream_loop(opts)
      end
    else
      conn
      |> put_status(405)
      |> json_error(Request.error(Request.not_found("SSE not supported")))
    end
  end

  # JSON-RPC response POST (e.g. elicitation response) → 202 Accepted per MCP spec §4
  defp dispatch(%Plug.Conn{body_params: params, method: "POST"} = conn, _opts)
       when is_map(params) and
              (is_map_key(params, "result") or is_map_key(params, "error")) and
              not is_map_key(params, "method") do
    session = conn.private.phantom.session

    case Request.build(params) do
      {:ok, request} ->
        session.router.dispatch_method([request.method, request.params, request, session])

        conn
        |> maybe_put_session_header(params, session.id)
        |> send_resp(202, "")

      {:error, _request} ->
        protocol_error(conn, nil, Request.invalid())
    end
  end

  # JSON-RPC notification POST (method, no id) → 202 Accepted per MCP spec §4
  defp dispatch(%Plug.Conn{body_params: params, method: "POST"} = conn, _opts)
       when is_map(params) and is_map_key(params, "method") and
              not is_map_key(params, "id") do
    session = conn.private.phantom.session

    with :ok <- validate_routing_headers(conn, params),
         {:ok, request} <- Request.build(params) do
      session = hydrate_from_meta(session, request)
      session.router.dispatch_method([request.method, request.params, request, session])

      conn
      |> maybe_put_session_header(params, session.id)
      |> send_resp(202, "")
    else
      {:error, error, id} -> protocol_error(conn, id, error)
      {:error, _request} -> protocol_error(conn, nil, Request.invalid())
    end
  end

  defp dispatch(%Plug.Conn{body_params: params, method: "POST"} = conn, opts)
       when is_map(params) or is_map_key(params, "_json") do
    case validate_routing_headers(conn, params) do
      :ok ->
        session = conn.private.phantom.session

        conn
        |> maybe_put_session_header(params, session.id)
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("x-accel-buffering", "no")
        |> start_stream()
        |> stream_loop(opts)

      {:error, error, id} ->
        protocol_error(conn, id, error)
    end
  end

  defp dispatch(%Plug.Conn{method: "DELETE"} = conn, _opts) do
    session = conn.private.phantom.session
    Phantom.Tracker.cast_session(session.pubsub, session.id, :finish)
    Phantom.Tracker.untrack_session(session.id)
    Phantom.SessionMeta.delete(session.pubsub, session.id)

    conn =
      case conn.private.phantom.router.terminate(session) do
        {:ok, _} -> send_resp(conn, 200, "")
        _ -> send_resp(conn, 204, "")
      end

    :telemetry.execute(
      [:phantom, :plug, :request, :terminate],
      %{},
      %{
        router: conn.private.phantom.router,
        session: conn.private.phantom.session,
        conn: conn
      }
    )

    conn
  end

  defp dispatch(%Plug.Conn{method: "POST"} = conn, _opts),
    do: protocol_error(conn, nil, Request.invalid())

  defp dispatch(conn, _opts) do
    conn
    |> put_status(405)
    |> json_error(
      Request.error(
        Request.not_found("Method not allowed. Use POST for JSON-RPC or GET for SSE.")
      )
    )
  end

  # SEP-2243: MCP 2026-07-28 mandates `Mcp-Method` and (where applicable)
  # `Mcp-Name` routing headers and that servers reject requests where the
  # headers and body disagree. Legacy clients on older protocol versions
  # are exempt — they predate the requirement.
  defp validate_routing_headers(_conn, %{"_json" => _}), do: :ok

  defp validate_routing_headers(conn, params) when is_map(params) do
    if Map.has_key?(params, "method") and not legacy_request?(conn),
      do: do_validate_routing_headers(conn, params),
      else: :ok
  end

  defp do_validate_routing_headers(conn, %{"method" => body_method} = params) do
    id = params["id"]
    header_method = mcp_header(conn, "mcp-method")
    body_name = name_from_params(body_method, Map.get(params, "params"))
    header_name = mcp_header(conn, "mcp-name") |> decode_header_value()

    needs_name? =
      body_method in [
        "tools/call",
        "prompts/get",
        "resources/read",
        "tasks/get",
        "tasks/update",
        "tasks/cancel"
      ]

    cond do
      is_nil(header_method) ->
        {:error, Request.header_mismatch("Missing required header: Mcp-Method"), id}

      header_method != body_method ->
        {:error,
         Request.header_mismatch(
           "Header mismatch: Mcp-Method header value '#{header_method}' does not match body value '#{body_method}'"
         ), id}

      needs_name? and is_nil(header_name) ->
        {:error, Request.header_mismatch("Missing required header: Mcp-Name"), id}

      needs_name? and header_name != body_name ->
        {:error,
         Request.header_mismatch(
           "Header mismatch: Mcp-Name header value '#{header_name}' does not match body value '#{body_name}'"
         ), id}

      true ->
        validate_param_headers(conn, params)
    end
  end

  defp name_from_params("resources/read", params) when is_map(params), do: params["uri"]
  defp name_from_params("tasks/" <> _, params) when is_map(params), do: params["taskId"]
  defp name_from_params(_method, params) when is_map(params), do: params["name"]
  defp name_from_params(_method, _params), do: nil

  defp validate_param_headers(conn, %{
         "id" => id,
         "method" => "tools/call",
         "params" => %{"name" => name} = method_params
       }) do
    session = conn.private.phantom.session

    declarations =
      session
      |> Cache.list(session.router, :tools)
      |> Enum.find(&(&1.name == name))
      |> case do
        nil -> []
        tool -> scan_param_headers(Phantom.Tool.JSONSchema.to_json(tool.input_schema))
      end

    args = Map.get(method_params, "arguments", %{})

    Enum.find_value(declarations, :ok, fn declaration ->
      case validate_param_header(conn, args, declaration) do
        :ok -> false
        {:error, error} -> {:error, error, id}
      end
    end)
  end

  defp validate_param_headers(_conn, _params), do: :ok

  # An argument declared with `x-mcp-header` must be mirrored in its
  # `Mcp-Param-*` header. Arguments that are absent need no header.
  defp validate_param_header(conn, args, {path, header, type}) do
    case value_at_path(args, path) do
      nil ->
        :ok

      value ->
        if param_header_matches?(conn, header, value, type),
          do: :ok,
          else:
            {:error,
             Request.header_mismatch(
               "Header mismatch: Mcp-Param-#{header} does not match body argument #{Enum.join(path, ".")}"
             )}
    end
  end

  defp param_header_matches?(conn, header, value, type) do
    with expected when is_binary(expected) <- primitive_header_value(value),
         actual when is_binary(actual) <- mcp_header(conn, "mcp-param-#{String.downcase(header)}"),
         decoded when is_binary(decoded) <- decode_header_value(actual) do
      matching_header_value?(decoded, value, expected, type)
    else
      _ -> false
    end
  end

  defp scan_param_headers(schema), do: scan_param_headers(schema, [])

  defp scan_param_headers(schema, path) when is_map(schema) do
    own =
      case {schema["x-mcp-header"] || schema[:"x-mcp-header"], schema[:type] || schema["type"]} do
        {header, type}
        when is_binary(header) and type in ["string", "integer", "number", "boolean"] and
               path != [] ->
          [{path, header, type}]

        _ ->
          []
      end

    properties = schema[:properties] || schema["properties"] || %{}

    Enum.reduce(properties, own, fn {key, child}, acc ->
      acc ++ scan_param_headers(child, path ++ [to_string(key)])
    end)
  end

  defp scan_param_headers(_schema, _path), do: []

  defp value_at_path(value, []), do: value

  defp value_at_path(value, [key | rest]) when is_map(value),
    do: value_at_path(value[key], rest)

  defp value_at_path(_value, _path), do: nil

  defp primitive_header_value(value) when is_binary(value), do: value
  defp primitive_header_value(true), do: "true"
  defp primitive_header_value(false), do: "false"
  defp primitive_header_value(value) when is_integer(value), do: Integer.to_string(value)
  defp primitive_header_value(value) when is_float(value), do: Float.to_string(value)
  defp primitive_header_value(_), do: nil

  defp matching_header_value?(decoded, value, _expected, type)
       when type in ["integer", "number"] and is_number(value) do
    case Float.parse(decoded) do
      {number, ""} -> number == value
      _ -> false
    end
  end

  defp matching_header_value?(decoded, _value, expected, _type), do: decoded == expected

  # Field values exclude the optional whitespace around them (RFC 9110 §5.5).
  defp mcp_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> String.replace(value, ~r/\A[ \t]+|[ \t]+\z/, "")
      [] -> nil
    end
  end

  # A value is Base64 only with both the `=?base64?` prefix and the `?=`
  # suffix; anything else is literal.
  defp decode_header_value("=?base64?" <> rest = value) do
    if String.ends_with?(rest, "?=") do
      case rest |> String.replace_suffix("?=", "") |> Base.decode64() do
        {:ok, decoded} -> decoded
        :error -> :invalid_base64_header
      end
    else
      value
    end
  end

  defp decode_header_value(value), do: value

  defp legacy_request?(%Plug.Conn{} = conn) do
    header_version = mcp_header(conn, "mcp-protocol-version")
    body_version = body_protocol_version(conn.body_params)

    not Request.modern?(header_version) and not Request.modern?(body_version) and
      not stateless_body?(conn.body_params)
  end

  defp stateless_body?(%{"params" => %{"_meta" => meta}}) when is_map(meta),
    do: Map.has_key?(meta, "io.modelcontextprotocol/protocolVersion")

  defp stateless_body?(_), do: false

  defp body_protocol_version(%{"params" => %{"_meta" => meta}}) when is_map(meta),
    do:
      meta["io.modelcontextprotocol/protocolVersion"] ||
        meta["protocolVersion"]

  defp body_protocol_version(_), do: nil

  defp maybe_put_session_header(conn, params, session_id) do
    header_version = mcp_header(conn, "mcp-protocol-version")
    meta_version = body_protocol_version(params)

    if Request.modern?(header_version) or Request.modern?(meta_version),
      do: conn,
      else: put_resp_header(conn, "mcp-session-id", session_id)
  end

  defp continue(state) do
    {state, exceptions} =
      state
      |> incoming_requests()
      |> Enum.reduce({state, []}, &process_request/2)

    maybe_reraise(state, exceptions)
  end

  defp incoming_requests(%{conn: %{method: "GET"}}), do: []

  defp incoming_requests(%{conn: %{body_params: %{"_json" => batch}}}), do: batch

  defp incoming_requests(%{conn: %{body_params: body}}), do: List.wrap(body)

  # Skip subsequent requests in a batch after the conn is halted.
  defp process_request(_request, {%{conn: %{halted: true}} = state, exceptions}),
    do: {state, exceptions}

  defp process_request(raw_request, {state, exceptions}) do
    case Request.build(raw_request) do
      {:ok, request} ->
        state
        |> prepare_for_dispatch(request)
        |> dispatch_or_reject(request, exceptions)

      {:error, error} ->
        state = state.stream_fun.(state, error.id, "message", error.response)
        {state, exceptions}
    end
  end

  defp prepare_for_dispatch(state, request) do
    state = maybe_track_response(state, request)
    state = put_in(state.conn, maybe_track_session_stream(state.conn))
    state = put_request_log_level(state, request)

    session =
      state.conn.private.phantom.session
      |> hydrate_from_meta(request)

    put_in(state.session, session)
  end

  defp put_request_log_level(state, %Request{} = request) do
    if Request.modern?(request) do
      log_level =
        Enum.find_value(Phantom.ClientLogger.log_levels(), 0, fn {name, grade} ->
          if Atom.to_string(name) == Request.log_level(request), do: grade
        end)

      Map.put(state, :log_level, log_level)
    else
      state
    end
  end

  # Under MCP 2026-07-28 every request is self-contained; the `_meta`
  # carries what `initialize` used to set on the session. Under legacy the
  # session has already been hydrated from Tracker meta (see
  # `inherit_session_meta/1`), so `_meta.clientInfo` and
  # `_meta.capabilities` will be absent and this is a no-op.
  defp hydrate_from_meta(session, %Phantom.Request{meta: meta} = request) when is_map(meta) do
    Session.hydrate_from_request(session, request)
  end

  defp hydrate_from_meta(session, _), do: session

  defp dispatch_or_reject(state, request, exceptions) do
    session_id = state.session.id

    case claim_in_flight(session_id, request) do
      :duplicate ->
        error = Request.error(request.id, Request.duplicate_request())
        state = state.stream_fun.(state, error[:id], "message", error)
        {state, exceptions}

      :ok ->
        subscribe_request(state.session, request)
        run_dispatch(state, request, exceptions)
    end
  end

  defp run_dispatch(state, request, exceptions) do
    result =
      state.session.router.dispatch_method([
        request.method,
        request.params,
        request,
        state.session
      ])

    handle_dispatch_result(result, state, request, exceptions)
  rescue
    exception ->
      error =
        Request.error(request.id, Request.internal_error(Exception.message(exception)))

      state = state.stream_fun.(state, request.id, "message", error)
      release_in_flight(state.session.id, request)
      {state, [{request, exception, __STACKTRACE__} | exceptions]}
  end

  defp handle_dispatch_result({:noreply, %Session{} = session}, state, request, exceptions) do
    # Async tool — in-flight claim stays held until `Session.respond/2`
    # eventually casts to the session GenServer and untracks.
    requests = Map.put(session.requests, request.id, request)
    {put_in(state.session, %{session | requests: requests}), exceptions}
  end

  defp handle_dispatch_result({:reply, result, %Session{} = session}, state, request, exceptions) do
    result = Request.normalize_result(result, request, session)
    request = Request.result(request, "message", result)
    state = put_in(state.session, session)
    state = state.stream_fun.(state, request.id, request.type, request.response)
    release_in_flight(state.session.id, request)
    {state, exceptions}
  end

  defp handle_dispatch_result({:error, error, %Session{} = session}, state, request, exceptions) do
    error = Request.error(request.id, error)
    state = put_in(state.session, session)
    state = state.stream_fun.(state, error[:id], "message", error)
    release_in_flight(state.session.id, request)
    {state, exceptions}
  end

  defp handle_dispatch_result({:error, error}, state, request, exceptions) do
    error = Request.error(request.id, error)
    state = state.stream_fun.(state, error[:id], "message", error)
    release_in_flight(state.session.id, request)
    {state, exceptions}
  end

  defp handle_dispatch_result(_response, state, request, exceptions) do
    error = Request.error(request.id, Request.internal_error())
    state = state.stream_fun.(state, error[:id], "message", error)
    release_in_flight(state.session.id, request)
    {state, exceptions}
  end

  defp cors_preflight(%Plug.Conn{halted: true} = conn, _opts), do: conn

  defp cors_preflight(%Plug.Conn{method: "OPTIONS"} = conn, opts) do
    origin = get_req_header(conn, "origin") |> List.first()

    if valid_origin?(origin, opts) do
      conn
      |> put_cors_headers(origin)
      |> send_resp(204, "")
      |> halt()
    else
      conn
      |> put_status(403)
      |> json_error(Request.error(Request.invalid("Origin not allowed")))
    end
  end

  defp cors_preflight(conn, _opts), do: conn

  defp cors_headers(%Plug.Conn{halted: true} = conn, _opts), do: conn

  defp cors_headers(conn, opts) do
    origin = get_req_header(conn, "origin") |> List.first()

    if valid_origin?(origin, opts) do
      put_cors_headers(conn, origin)
    else
      conn
    end
  end

  defp put_cors_headers(conn, origin) do
    param_headers =
      conn
      |> get_req_header("access-control-request-headers")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(String.downcase(&1), "mcp-param-"))

    allowed_headers =
      [
        "content-type",
        "authorization",
        "mcp-session-id",
        "last-event-id",
        "mcp-protocol-version",
        "mcp-method",
        "mcp-name"
        | param_headers
      ]
      |> Enum.uniq()
      |> Enum.join(", ")

    conn
    |> put_resp_header(
      "access-control-expose-headers",
      "last-event-id, mcp-session-id, mcp-protocol-version, mcp-method, mcp-name"
    )
    |> put_resp_header("access-control-allow-origin", origin || "*")
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
    |> put_resp_header(
      "access-control-allow-headers",
      allowed_headers
    )
    |> put_resp_header("access-control-max-age", "86400")
  end

  # MCP 2026-07-28 maps some JSON-RPC errors to an HTTP status, so a modern
  # POST sends its status with the first message instead of up front.
  defp start_stream(%Plug.Conn{private: %{phantom: %{modern: true}}} = conn), do: conn
  defp start_stream(conn), do: send_chunked(conn, 200)

  defp stream_fun(%{conn: %{halted: false, state: :unset} = conn} = state, id, event, payload) do
    case payload do
      %{error: %{code: code}} when is_map_key(@error_http_statuses, code) ->
        conn =
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(Map.fetch!(@error_http_statuses, code), JSON.encode!(payload))

        put_in(state.conn, conn)

      _ ->
        stream_fun(put_in(state.conn, send_chunked(conn, 200)), id, event, payload)
    end
  end

  defp stream_fun(%{conn: %{state: :sent}} = state, _id, _event, _payload), do: state

  defp stream_fun(%{conn: %{halted: false} = conn} = state, _id, event, payload) do
    conn = send_sse_event(conn, event, payload)
    put_in(state.conn, conn)
  end

  defp stream_fun(%{session: %{pubsub: pubsub}} = state, _id, _event, _payload)
       when is_atom(pubsub) do
    state
  end

  if Mix.env() == :test do
    defp do_stream_fun(fun, listener) when is_pid(listener) do
      fn state, id, event, payload ->
        send(listener, {:response, id, event, payload})
        fun.(state, id, event, payload)
      end
    end

    defp do_stream_fun(fun, _listener), do: fun
  else
    defp do_stream_fun(fun, _), do: fun
  end

  defp stream_loop(conn, opts) do
    try do
      Session.start_loop(
        conn: conn,
        pubsub: opts.pubsub,
        continue_fun: &continue/1,
        session: conn.private.phantom.session,
        timeout: opts.session_timeout,
        stream_fun: do_stream_fun(&stream_fun/4, opts[:listener])
      )
    catch
      :exit, :normal -> final_conn(conn)
      :exit, :shutdown -> final_conn(conn)
      :exit, {:shutdown, _} -> final_conn(conn)
    after
      untrack(opts)

      # Bandit re-uses the same process for new requests,
      # therefore we need to unregister manually and clear
      # any pending messages from the inbox
      clear_inbox()
      send(self(), {:plug_conn, :sent})
      disconnect(conn)
    end
  end

  defp final_conn(conn) do
    receive do
      {:phantom_final_conn, final} -> final
    after
      0 -> conn
    end
  end

  defp untrack(opts) do
    if opts.pubsub do
      Phantom.Tracker.untrack(self())
    end
  end

  defp clear_inbox do
    receive do
      _ -> clear_inbox()
    after
      0 -> :ok
    end
  end

  # SSE event ids must be unique within a session, so JSON-RPC ids (chosen by
  # the client, and free to repeat) are not used. Streams are not resumable,
  # so events carry no id.
  defp send_sse_event(conn, "comment", _data) do
    case chunk(conn, ": keepalive\n\n") do
      {:ok, conn} ->
        conn

      {:error, reason} ->
        disconnect(conn)
        exit({:shutdown, {:stream_closed, reason}})
    end
  end

  defp send_sse_event(conn, _event_type, nil) do
    data = ["event: message\n", "data: \"\"\n\n"]

    case chunk(conn, data) do
      {:ok, conn} ->
        conn

      {:error, reason} ->
        disconnect(conn)
        exit({:shutdown, {:stream_closed, reason}})
    end
  end

  defp send_sse_event(conn, event_type, %{} = data) do
    send_sse_event(conn, event_type, JSON.encode!(data))
  end

  defp send_sse_event(conn, event_type, data) when is_binary(data) do
    data = ["event: #{event_type}\n", "data: #{data}\n\n"]

    case chunk(conn, data) do
      {:ok, conn} ->
        conn

      {:error, reason} ->
        disconnect(conn)
        exit({:shutdown, {:stream_closed, reason}})
    end
  end

  defp valid_origin?(_origin, %{validate_origin: false}), do: true
  defp valid_origin?(_origin, %{origins: :all}), do: true
  defp valid_origin?(nil, _opts), do: true

  defp valid_origin?(origin, opts) do
    case opts[:origins] do
      :all -> true
      origins when is_list(origins) -> origin in origins
      {m, f, a} -> apply(m, f, [origin | a]) == true
      _ -> false
    end
  end

  defp valid_host?(_host, :all), do: true
  defp valid_host?(host, {m, f, a}), do: apply(m, f, [host | a]) == true

  defp valid_host?(host, hosts) when is_list(hosts),
    do: normalize_host(host) in Enum.map(hosts, &normalize_host/1)

  # Hosts are case-insensitive, and adapters differ on keeping IPv6 brackets.
  defp normalize_host(host),
    do: host |> String.downcase() |> String.trim_leading("[") |> String.trim_trailing("]")

  defp get_origin(conn) do
    get_req_header(conn, "origin") |> List.first()
  end

  defp reported_content_length_exceeded?(conn, opts) do
    case get_req_header(conn, "content-length") do
      [length_str] ->
        case Integer.parse(length_str) do
          {length, ""} -> length > opts[:max_request_size]
          _ -> false
        end

      _ ->
        false
    end
  end

  defp json_error(conn, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || 400, JSON.encode!(error))
    |> disconnect()
  end

  defp disconnect(conn) do
    conn =
      case conn.private.phantom.router.disconnect(conn.private.phantom.session) do
        {:ok, session} -> put_in(conn.private.phantom.session, session)
        _ -> conn
      end

    :telemetry.execute(
      [:phantom, :plug, :request, :disconnect],
      %{},
      %{
        router: conn.private.phantom.router,
        session: conn.private.phantom.session,
        conn: conn
      }
    )

    halt(conn)
  end

  defp maybe_reraise(state, []), do: state

  defp maybe_reraise(state, exceptions) do
    for {request, exception, stacktrace} <- exceptions do
      :telemetry.execute(
        [:phantom, :plug, :request, :exception],
        %{},
        %{
          session: state.conn.private.phantom.session,
          conn: state.conn,
          stacktrace: stacktrace,
          request: request,
          exception: exception
        }
      )
    end

    case exceptions do
      [{_, exception, stacktrace}] ->
        reraise exception, stacktrace

      exceptions ->
        raise Phantom.ErrorWrapper.new(
                "Exceptions while processing MCP requests",
                exceptions
              )
    end
  end

  @doc """
  Construct a WWW-Authenticate header as defined by RFC 9728 from the map.

  This requires the map to contain a `:method` to indicate acceptable authentication
  methods, typically `"Bearer"`, and then rest of the attributes will be serialized
  into the header as key=value.

  For example,

      iex> Phantom.Plug.www_authenticate(%{
      ...>   method: "Bearer",
      ...>   resource_metadata: "https://myapp.com/.well-known/oauth-protected-resource",
      ...>   max_age: 42000
      ...> })
      ~s|Bearer max_age="42000", resource_metadata="https://myapp.com/.well-known/oauth-protected-resource"|

  https://datatracker.ietf.org/doc/html/rfc9728#name-use-of-www-authenticate-for
  """
  @type www_authenticate :: %{
          required(:method) => String.t(),
          optional(String.t() | atom()) => atom() | String.t()
        }
  @spec www_authenticate(map()) :: String.t()
  def www_authenticate(info) do
    info = Map.new(info)
    {method, info} = Map.pop(info, :method)

    info =
      Enum.map_join(info, ", ", fn {key, value} ->
        "#{key}=#{inspect(to_string(value))}"
      end)

    "#{method} #{info}"
  end

  # Methods that dispatch to user-defined handlers and may have
  # side effects (including elicitation). Other methods — tools/list,
  # prompts/list, initialize, ping — are idempotent and safe to
  # re-dispatch, so we don't dedupe them (retries on reconnect stay
  # working).
  @dedupable_methods ~w[tools/call prompts/get]

  defp claim_in_flight(session_id, %Request{id: id, method: method})
       when method in @dedupable_methods and not is_nil(id),
       do: Phantom.Tracker.track_in_flight(session_id, id)

  defp claim_in_flight(_session_id, _request), do: :ok

  # `Phantom.Session.notify_progress/4` reaches the request through this topic.
  defp subscribe_request(session, %Request{id: id, method: method})
       when method in @dedupable_methods and not is_nil(id),
       do: Phantom.Tracker.subscribe_request(session.pubsub, session.id, id)

  defp subscribe_request(_session, _request), do: :ok

  defp release_in_flight(session_id, %Request{id: id, method: method})
       when method in @dedupable_methods and not is_nil(id),
       do: Phantom.Tracker.untrack_in_flight(session_id, id)

  defp release_in_flight(_session_id, _request), do: :ok

  defp inherit_session_meta(%Session{} = session) do
    case Phantom.SessionMeta.get(session.id) do
      %{client_capabilities: caps, client_info: info} ->
        %{session | client_capabilities: caps, client_info: info || session.client_info}

      nil ->
        session
    end
  end

  defp maybe_track_response(state, %{response: %{}, id: id}) when is_binary(id) do
    Phantom.Tracker.track_request(self(), id)
    state
  end

  defp maybe_track_response(state, _), do: state

  # The GET stream is the session's stream for server-initiated messages.
  # A POST's stream, `initialize` included, closes after its response.
  defp maybe_track_session_stream(conn) do
    session_id = conn.private.phantom.session.id

    case {conn.method, Phantom.Tracker.list_session_streams(session_id)} do
      # Only if no stream exists for the session (on any node)
      {"GET", []} ->
        session = %{conn.private.phantom.session | close_after_complete: false}

        Phantom.Tracker.track_session(
          self(),
          session.id,
          %{}
        )

        Phantom.Tracker.subscribe_session(session.pubsub, session.id)

        put_in(conn.private.phantom.session, session)

      {"GET", _existing} ->
        conn
        |> put_status(409)
        |> json_error(
          Request.error(%{
            code: -32000,
            message: "Only one SSE stream is allowed per session"
          })
        )

      _ ->
        conn
    end
  end
end

defmodule Phantom.Plug do
  @default_opts [
    origins: ["http://localhost:4000"],
    validate_origin: true,
    session_timeout: 300_000,
    max_request_size: 1_048_576
  ]

  @moduledoc """
   Main Plug implementation for MCP HTTP transport with SSE support.

   This module provides a complete MCP server implementation with:
   - JSON-RPC 2.0 message handling
   - Server-Sent Events (SSE) streaming
   - CORS handling and security features
   - Session management integration
   - Origin validation

   In your Phoenix router where you can accept JSON:

        pipeline :mcp do
          plug :accepts, ["json"]
        end

        scope "/mcp" do
          pipe_through :mcp

          forward "/", Phantom.Plug,
            router: Test.MCPRouter,
            validate_origin: false
        end

    For in your Plug Router after you parse the body:

        use Plug.Router
        plug :match
        plug Plug.Parsers,
          parsers: [{:json, length: 1_000_000}],
          pass: ["application/json"],
          json_decoder: JSON
        plug :dispatch

        forward "/mcp",
          to: Phantom.Plug,
          init_opts: [validate_origin: false, router: Test.MCPRouter]

  Here are the defaults:

  ```elixir
  #{inspect(@default_opts, pretty: true)}
  ```

  ## Telemetry

  Telemetry is provided with these events:

  - `[:phantom, :plug, :request, :connect]` with meta: `~w[session_id last_event_id router opts conn]a`
  - `[:phantom, :plug, :request, :disconnect]` with meta: `~w[session router conn]a`
  - `[:phantom, :plug, :request, :exception]` with meta: `~w[session router conn stacktrace request exception]a`
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @type opts :: [
          router: module(),
          origins: [String.t()] | :all | mfa(),
          validate_origin: boolean(),
          session_timeout: pos_integer(),
          max_request_size: pos_integer()
        ]

  @doc """
  Initializes the plug with the given options.

  ## Options

  - `:router` - The MCP router module (required)
  - `:origins` - List of allowed origins or `:all` (default: localhost)
  - `:validate_origin` - Whether to validate Origin header (default: true)
  - `:session_timeout` - Session timeout in milliseconds (default: 300_000)
  - `:max_request_size` - Maximum request size in bytes (default: 1MB)
  """
  def init(opts) do
    router = Keyword.fetch!(opts, :router)
    Code.ensure_loaded!(router)

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
      has_error: false,
      session: nil,
      request: nil,
      state: :stateless
    })
    |> validate_request(config)
    |> cors_preflight(config)
    |> cors_headers(config)
    |> connect(config)
    |> dispatch(config)
  end

  defp connect(conn, opts) do
    session_id = get_req_header(conn, "mcp-session-id") |> List.first()
    last_event_id = get_req_header(conn, "last-event-id") |> List.first()
    router = opts[:router]

    if not Phantom.Cache.initialized?(router) do
      Phantom.Cache.register(router)
    end

    :telemetry.execute(
      [:phantom, :plug, :request, :connect],
      %{},
      %{
        session_id: session_id,
        last_event_id: last_event_id,
        router: router,
        opts: opts,
        conn: conn
      }
    )

    session = Phantom.Session.new(session_id, conn, transport_pid: conn.owner, router: router)

    try do
      case router.connect(session, last_event_id) do
        {:ok, session} ->
          put_in(conn.private.phantom.session, session)

        {:error, error} when is_map(error) ->
          json_error(conn, error)

        {:error, reason} ->
          json_error(conn, %{
            code: -32603,
            message: "Connection failed: #{reason}"
          })
      end
    rescue
      e ->
        :telemetry.execute(
          [:phantom, :plug, :request, :exception],
          %{},
          %{conn: conn, stacktrace: __STACKTRACE__, exception: e}
        )

        json_error(conn, %{
          code: -32603,
          message: "Connection failed: internal server error"
        })

        reraise(e, __STACKTRACE__)
    end
  end

  defp validate_request(conn, opts) do
    cond do
      opts[:validate_origin] && not valid_origin?(get_origin(conn), opts) ->
        conn
        |> put_status(403)
        |> json_error(%{code: -32600, message: "Origin not allowed"})

      reported_content_length_exceeded?(conn, opts) ->
        conn
        |> put_status(413)
        |> json_error(%{code: -32600, message: "Request too large"})

      conn.method not in ~w[GET OPTIONS POST] ->
        conn
        |> put_status(405)
        |> json_error(%{code: -32601, message: "Method not allowed"})

      conn.method not in ~w[GET OPTIONS] and map_size(conn.body_params) == 0 ->
        conn
        |> put_status(400)
        |> json_error(%{code: -32700, message: "Parse error: Invalid JSON"})

      conn.body_params["_json"] == [] ->
        conn
        |> put_status(400)
        |> json_error(%{code: -32600, message: "Invalid Request"})

      true ->
        conn
    end
  end

  defp dispatch(%Plug.Conn{halted: true} = conn, _opts), do: conn

  defp dispatch(%Plug.Conn{method: "GET"} = conn, opts) do
    session = conn.private.phantom.session

    if conn.private.phantom.session.transport_pid do
      conn
      |> put_resp_header("mcp-session-id", session.id)
      |> start_sse_stream(opts)
      |> stream_session_events(opts)
    else
      conn
      |> put_status(405)
      |> json_error(%{code: -32601, message: "SSE not supported"})
    end
  end

  defp dispatch(
         %Plug.Conn{body_params: %Plug.Conn.Unfetched{}, method: "POST"} = conn,
         _opts
       ) do
    # TODO, better error handling here
    conn
    |> put_status(400)
    |> json_error(%{code: -32700, message: "Parse error: Invalid JSON"})
  end

  defp dispatch(%Plug.Conn{body_params: body, method: "POST"} = conn, opts)
       when is_map(body) or is_list(body) do
    case process_json_rpc(opts[:router], conn, opts) do
      {:json, [], [], conn} ->
        conn
        |> send_resp(200, "")
        |> disconnect()

      {:json, result, [], conn} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, JSON.encode!(result))
        |> disconnect()

      {:json, result, exceptions, conn} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, JSON.encode!(result))
        |> disconnect()
        |> maybe_reraise(exceptions)

      {:sse, results, exceptions, conn} ->
        conn = start_sse_stream(conn, opts)
        Enum.each(results, &send_sse_event(conn, "result", &1))

        conn
        |> stream_session_events(opts)
        |> maybe_reraise(exceptions)

      {:error, error} ->
        conn
        |> put_status(400)
        |> json_error(error)
    end
  end

  defp dispatch(%Plug.Conn{method: "POST"} = conn, _opts) do
    conn
    |> put_status(400)
    |> json_error(%{code: -32600, message: "Invalid Request"})
  end

  defp dispatch(conn, _opts) do
    conn
    |> put_status(405)
    |> json_error(%{
      code: -32601,
      message: "Method not allowed. Use POST for JSON-RPC or GET for SSE."
    })
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
      |> json_error(%{code: -32600, message: "Origin not allowed"})
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
    conn
    |> put_resp_header("access-control-expose-headers", "last-event-id, mcp-session-id")
    |> put_resp_header("access-control-allow-origin", origin || "*")
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header(
      "access-control-allow-headers",
      "content-type, authorization, mcp-session-id, last-event-id"
    )
    |> put_resp_header("access-control-max-age", "86400")
  end

  defp start_sse_stream(conn, _opts) do
    conn =
      conn.private.phantom.state
      |> put_in(:streaming)
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(202)

    send_sse_event(conn, "connected", %{session_id: conn.private.phantom.session.id})
    conn
  end

  defp stream_session_events(conn, opts) do
    %{id: session_id} = conn.private.phantom.session

    receive do
      {:session_event, ^session_id, event_type, data} ->
        case send_sse_event(conn, event_type, data) do
          {:ok, conn} -> stream_session_events(conn, opts)
          {:error, _} -> conn
        end

      {:session_closed, _reason} ->
        send_sse_event(conn, "closed", nil)
        conn

      {:timeout, ^session_id} ->
        send_sse_event(conn, "timeout", %{message: "Session timeout"})
        conn
    after
      30_000 ->
        case send_sse_event(conn, "ping", %{}) do
          {:ok, conn} -> stream_session_events(conn, opts)
          {:error, _} -> conn
        end
    end
  end

  defp send_sse_event(conn, event_type, %{} = data) do
    send_sse_event(conn, event_type, JSON.encode!(data))
  end

  defp send_sse_event(conn, event_type, data) when is_binary(data) do
    send_sse_event(conn, event_type, data)
  end

  defp send_sse_event(conn, event_type, nil) do
    chunk(conn, [
      "id: #{conn.private.phantom.session.id}\n",
      "event: #{event_type}\n"
    ])
  end

  defp send_sse_event(conn, event_type, data) when is_binary(data) do
    chunk(conn, ["id: #{UUIDv7.generate()}\n", "event: #{event_type}\n", "data: #{data}\n\n"])
  end

  # Batch request
  defp process_json_rpc(router, %{body_params: %{"_json" => requests}} = conn, opts) do
    {stream_result?, results, exceptions, conn} =
      Enum.reduce(
        requests,
        {false, [], [], conn},
        fn request, {streaming?, results, exceptions, conn_acc} ->
          try do
            case process_request(router, conn_acc, request, opts) do
              {nil, conn_acc} ->
                {streaming?, results, exceptions, conn_acc}

              {:sse, conn_acc} ->
                {true, results, exceptions, conn_acc}

              {:json, result, conn_acc} ->
                {streaming?, [result | results], exceptions, conn_acc}
            end
          rescue
            exception ->
              result = format_error(Exception.message(exception))

              {streaming?, [result | results],
               [{request, exception, __STACKTRACE__} | exceptions], conn}
          end
        end
      )

    results = Enum.reverse(results)
    exceptions = Enum.reverse(exceptions)

    cond do
      stream_result? and streaming?(conn) ->
        {:sse, results, exceptions, conn}

      stream_result? and not streaming?(conn) ->
        # TODO: This is not working as intended. For now, this is dropping async results
        # Option 1: This should be caught at compile-time somehow and not allow
        #   async results when session management is disabled.
        # Option 2: Wait up to n seconds to collect and then send, dropping rest?
        # Option 3: Buffer async results and send on next connection?
        {:json, results, exceptions, conn}

      true ->
        {:json, results, exceptions, conn}
    end
  end

  defp process_json_rpc(router, %{body_params: request} = conn, opts) do
    try do
      case process_request(router, conn, request, opts) do
        {nil, conn} -> {:json, [], [], conn}
        {:sse, conn} -> {:sse, [], [], conn}
        {:json, result, conn} -> {:json, result, [], conn}
      end
    rescue
      exception ->
        result = format_error(Exception.message(exception))
        {:json, result, [{request, exception, __STACKTRACE__}], put_status(conn, 500)}
    end
  end

  defp process_json_rpc(_router, _conn, _opts) do
    {:error, %{code: -32600, message: "Invalid Request"}}
  end

  defp process_request(router, conn, request, _opts) do
    request_id = Map.get(request, "id")

    with {:ok, method, params} <- validate_json_rpc(conn, request) do
      case router.dispatch_method([method, params, request, conn.private.phantom.session]) do
        {:reply, result, session} ->
          conn = put_in(conn.private.phantom.session, session)
          {:json, %{id: request_id, jsonrpc: "2.0", result: result}, conn}

        {:noreply, session} ->
          conn = put_in(conn.private.phantom.session, session)
          {:sse, conn}

        {:notification, session} ->
          {nil, put_in(conn.private.phantom.session, session)}

        {:error, error, session} ->
          conn = put_in(conn.private.phantom.session, session)
          conn = put_in(conn.private.phantom.has_error, true)
          {:json, %{id: request_id, jsonrpc: "2.0", error: format_error(error)}, conn}

        :not_found ->
          conn = put_in(conn.private.phantom.has_error, true)

          {:json,
           %{id: request_id, jsonrpc: "2.0", error: %{code: -32601, message: "Method not found"}},
           conn}

        _ ->
          conn = put_in(conn.private.phantom.has_error, true)

          {:json,
           %{id: request_id, jsonrpc: "2.0", error: %{code: -32603, message: "Internal error"}},
           conn}
      end
    end
  end

  defp validate_json_rpc(_conn, %{"jsonrpc" => "2.0", "method" => method} = request)
       when is_binary(method) do
    {:ok, method, Map.get(request, "params", %{})}
  end

  defp validate_json_rpc(conn, request) do
    {:json,
     %{id: request["id"], jsonrpc: "2.0", error: %{code: -32600, message: "Invalid Request"}},
     conn}
  end

  defp valid_origin?(nil, %{validate_origin: false}), do: true
  defp valid_origin?(nil, _opts), do: false

  defp valid_origin?(_origin, %{validate_origin: false}), do: true

  defp valid_origin?(origin, opts) do
    case opts[:origins] do
      :all -> true
      origins when is_list(origins) -> origin in origins
      {m, f, a} -> apply(m, f, [origin | a])
      _ -> false
    end
  end

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

  defp format_error(error) when is_map(error), do: error

  defp format_error(error) when is_binary(error) do
    %{code: -32603, message: error}
  end

  defp format_error(error) do
    %{code: -32603, message: "Internal error: #{inspect(error)}"}
  end

  defp json_error(conn, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      conn.status || 400,
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: conn.body_params["id"],
        error: error
      })
    )
    |> disconnect()
  end

  defp disconnect(conn) do
    conn.private.phantom.router.disconnect(conn.private.phantom.session)

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

  defp streaming?(conn), do: conn.private.phantom.state == :streaming

  defp maybe_reraise(conn, []), do: conn

  defp maybe_reraise(conn, exceptions) do
    for {request, exception, stacktrace} <- exceptions do
      :telemetry.execute(
        [:phantom, :plug, :request, :exception],
        %{},
        %{
          session: conn.private.phantom.session,
          conn: conn,
          stacktrace: stacktrace,
          request: request,
          exception: exception
        }
      )
    end

    raise Phantom.ErrorWrapper.new(
            "Exceptions while processing MCP requests",
            exceptions
          )
  end
end

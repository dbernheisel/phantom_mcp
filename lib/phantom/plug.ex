defmodule Phantom.Plug do
  @default_opts [
    pubsub: nil,
    origins: ["http://localhost:4000"],
    validate_origin: true,
    session_timeout: :timer.seconds(30),
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

  alias Phantom.Request
  alias Phantom.Session

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
  - `:session_timeout` - Session timeout in milliseconds (default: 30s)
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
    |> put_private(:phantom, %{router: config.router, session: nil, requests: %{}})
    |> validate_request(config)
    |> cors_preflight(config)
    |> cors_headers(config)
    |> connect(config)
    |> dispatch(config)
  end

  defp connect(conn, opts) do
    # TODO
    # last_event_id =
    #   if conn.method == "GET",
    #     do: get_req_header(conn, "last-event-id") |> List.first(),
    #     else: nil
    router = opts[:router]

    if not Phantom.Cache.initialized?(router) do
      Phantom.Cache.register(router)
    end

    session =
      Session.new(get_req_header(conn, "mcp-session-id") |> List.first(),
        close_after_complete: conn.method != "GET",
        pubsub: opts.pubsub,
        pid: conn.owner,
        router: router
      )

    try do
      case router.connect(session, conn.req_headers) do
        {:ok, session} ->
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

        {:error, error} when is_map(error) ->
          json_error(conn, Request.error(Request.closed(JSON.encode!(error))))

        {:error, reason} ->
          json_error(
            conn,
            Request.error(Request.closed("Connection failed: #{reason}"))
          )
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

  defp validate_request(conn, opts) do
    cond do
      opts[:validate_origin] && not valid_origin?(get_origin(conn), opts) ->
        conn
        |> put_status(403)
        |> json_error(Request.error(Request.closed("Origin not allowed")))

      reported_content_length_exceeded?(conn, opts) ->
        conn
        |> put_status(413)
        |> json_error(Request.error(Request.invalid("Request too large")))

      conn.method not in ~w[DELETE GET OPTIONS POST] ->
        conn
        |> put_status(405)
        |> json_error(Request.error(Request.not_found("Method not allowed")))

      conn.method not in ~w[DELETE GET OPTIONS] and map_size(conn.body_params) == 0 ->
        conn
        |> put_status(400)
        |> json_error(Request.error(Request.parse_error("Parse error: Invalid JSON")))

      conn.body_params["_json"] == [] ->
        conn
        |> put_status(400)
        |> json_error(Request.error(Request.parse_error("No requests")))

      true ->
        conn
    end
  end

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
      session = conn.private.phantom.session
      Phoenix.Tracker.track(Phantom.Tracker, self(), "sessions", session.id, %{})

      conn
      |> put_resp_header("mcp-session-id", session.id)
      |> start_sse_stream(opts)
      |> stream_loop(opts)
    else
      conn
      |> put_status(405)
      |> json_error(Request.error(Request.not_found("SSE not supported")))
    end
  end

  defp dispatch(%Plug.Conn{body_params: params, method: "POST"} = conn, opts)
       when is_map(params) or is_map_key(params, "_json") do
    session = conn.private.phantom.session

    conn
    |> put_resp_header("mcp-session-id", session.id)
    |> start_sse_stream(opts)
    |> stream_loop(opts)
  end

  defp dispatch(%Plug.Conn{method: "DELETE"} = conn, _opts) do
    case conn.private.phantom.router.terminate(conn.private.phantom.session) do
      {:ok, _} -> send_resp(conn, 200, "")
      _ -> send_resp(conn, 204, "")
    end
  end

  defp dispatch(%Plug.Conn{method: "POST"} = conn, _opts) do
    conn
    |> put_status(400)
    |> json_error(Request.error(Request.invalid()))
  end

  defp dispatch(conn, _opts) do
    conn
    |> put_status(405)
    |> json_error(
      Request.error(
        Request.not_found("Method not allowed. Use POST for JSON-RPC or GET for SSE.")
      )
    )
  end

  defp continue(state) do
    stream_fun = state.stream_fun

    params =
      cond do
        state.conn.method == "GET" -> []
        is_map_key(state.conn.body_params, "_json") -> state.conn.body_params["_json"]
        true -> List.wrap(state.conn.body_params)
      end

    {state, exceptions} =
      Enum.reduce(
        params,
        {state, []},
        fn
          _request, {%{conn: %{halted: true}} = state_acc, exceptions_acc} ->
            {state_acc, exceptions_acc}

          request, {state_acc, exceptions_acc} ->
            case Request.build(request) do
              {:ok, request} ->
                try do
                  case state_acc.session.router.dispatch_method([
                         request.method,
                         request.params,
                         request,
                         state_acc.session
                       ]) do
                    {:noreply, %Session{} = session_acc} ->
                      requests = Map.put(session_acc.requests, request.id, request.response)
                      state_acc = put_in(state_acc.session, %{session_acc | requests: requests})
                      {state_acc, exceptions_acc}

                    {:reply, result, %Session{} = session_acc} ->
                      request = Request.result(request, "message", result)
                      state_acc = put_in(state_acc.session, session_acc)

                      state_acc =
                        stream_fun.(state_acc, request.id, request.type, request.response)

                      {state_acc, exceptions_acc}

                    {:error, error, %Session{} = session_acc} ->
                      error = Request.error(request.id, error)
                      state_acc = put_in(state_acc.session, session_acc)
                      state_acc = stream_fun.(state_acc, error[:id], "message", error)
                      {state_acc, exceptions_acc}

                    {:error, error} ->
                      error = Request.error(request.id, error)
                      state_acc = stream_fun.(state_acc, error[:id], "message", error)
                      {state_acc, exceptions_acc}

                    _ ->
                      error = Request.error(request.id, Request.internal_error())
                      state_acc = stream_fun.(state_acc, error[:id], "message", error)
                      {state_acc, exceptions_acc}
                  end
                rescue
                  exception ->
                    error =
                      Request.error(
                        request.id,
                        Request.internal_error(Exception.message(exception))
                      )

                    exceptions_acc = [{request, exception, __STACKTRACE__} | exceptions_acc]
                    state_acc = stream_fun.(state_acc, request.id, "message", error)
                    {state_acc, exceptions_acc}
                end

              {:error, error} ->
                state_acc = stream_fun.(state_acc, error.id, "message", error.response)
                {state_acc, exceptions_acc}
            end
        end
      )

    maybe_reraise(state, exceptions)
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
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  defp stream_fun(%{conn: %{halted: false} = conn} = state, id, event, payload) do
    conn = send_sse_event(conn, id, event, payload)
    put_in(state.conn, conn)
  end

  defp stream_fun(%{session: %{pubsub: pubsub}} = state, id, _event, _payload)
       when is_atom(pubsub) do
    Logger.warning("Dropping request #{id} since connection closed")
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
      :exit, :normal -> conn
      :exit, :shutdown -> conn
      :exit, {:shutdown, _} -> conn
    after
      # Bandit re-uses the same process for new requests,
      # therefore we need to unregister manually and clear
      # any pending messages from the inbox
      if conn.method == "GET" and opts.pubsub do
        Phoenix.Tracker.untrack(
          Phantom.Tracker,
          self(),
          "phantom",
          conn.private.phantom.session.id
        )
      end

      clear_inbox()
      send(self(), {:plug_conn, :sent})
      disconnect(conn)
    end
  end

  defp clear_inbox do
    receive do
      _ -> clear_inbox()
    after
      0 -> :ok
    end
  end

  defp send_sse_event(conn, id, _event_type, nil) do
    id = if id, do: ["id: #{id}\n"], else: []
    data = id ++ ["event: message\n", "data: \"\"\n\n"]

    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _} -> disconnect(conn)
    end
  end

  defp send_sse_event(conn, id, event_type, %{} = data) do
    send_sse_event(conn, id, event_type, JSON.encode!(data))
  end

  defp send_sse_event(conn, id, event_type, data) when is_binary(data) do
    id = if id, do: ["id: #{id}\n"], else: []
    data = id ++ ["event: #{event_type}\n", "data: #{data}\n\n"]

    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _} -> disconnect(conn)
    end
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

    raise Phantom.ErrorWrapper.new(
            "Exceptions while processing MCP requests",
            exceptions
          )
  end
end

defmodule Phantom.A2A.Plug do
  @default_opts [
    pubsub: nil,
    origins: ["http://localhost:4000"],
    validate_origin: true,
    hosts: :all,
    mount: nil,
    blocking_timeout: :timer.seconds(60),
    card_max_age: 300,
    bindings: [:jsonrpc, :http_json],
    keepalive: :timer.seconds(15),
    push_notifications: true,
    extended_card: true,
    max_request_size: 1_048_576
  ]

  @moduledoc """
  Serve a router's A2A agents over the JSON-RPC and HTTP+JSON bindings.

  Mount it under a path, and optionally serve one agent's card at the
  well-known path. Mount it without `Plug.Parsers`: it reads the body itself,
  so a request with invalid JSON gets the error A2A requires rather than the
  parser's 400. A body that is already parsed is used as is.

      get "/.well-known/agent-card.json", Phantom.A2A.Plug,
        router: MyApp.MCP.Router,
        mount: "/a2a"

      scope "/a2a" do
        forward "/", Phantom.A2A.Plug, router: MyApp.MCP.Router, pubsub: MyApp.PubSub
      end

  Each `agent "research", ...` route in the router is then served at:

    * `GET /a2a/research/agent-card.json` - the agent's card
    * `POST /a2a/research` - JSON-RPC requests
    * the HTTP+JSON routes under `/a2a/research`, from the A2A protobuf:
      `POST message:send`, `POST message:stream`, `GET tasks`,
      `GET tasks/{id}`, `POST tasks/{id}:cancel`, `GET` or
      `POST tasks/{id}:subscribe`, `GET extendedAgentCard`, and
      `POST`, `GET`, and `DELETE` on `tasks/{id}/pushNotificationConfigs`.
      A segment before them names a tenant, as in `/a2a/research/acme/message:send`.

  Both bindings serve the same methods, and the card lists both. HTTP+JSON
  answers with `application/a2a+json`, and with errors as `google.rpc.Status`
  under their HTTP status.

  The well-known path serves the card of the agent named by the router's
  `a2a: [well_known: "research"]` option.

  Requests must send an `A2A-Version` header for version 1. Each request
  calls `c:Phantom.Router.connect/2` with the conn and the request in
  `conn.body_params`: the JSON-RPC request, or for HTTP+JSON,
  `%{"method" => method, "params" => params}` in the same shape. Agents
  excluded with `Phantom.Session.allow_agents/2` are not found. Cards are
  public.

  ## Options

    * `:router` - the `Phantom.Router` (required)
    * `:bindings` - which bindings to serve (default `[:jsonrpc, :http_json]`)
    * `:pubsub` - a `Phoenix.PubSub` server, which `Phantom.A2A.publish/2`
      sends events through. Like `Phantom.Plug`, options also come from the
      router's application config, so one `pubsub` there serves both plugs. With it, cards advertise streaming,
      `SendStreamingMessage` and `SubscribeToTask` stream events over SSE, and
      `SendMessage` waits for the task to finish or need input. Without it,
      `SendMessage` returns the task as the agent returned it.
    * `:blocking_timeout` - how long `SendMessage` waits for a task to finish
      or need input before returning it as it is (default 60 seconds)
    * `:mount` - the path the agents are forwarded from, for the well-known
      route, such as `"/a2a"`
    * `:card_max_age` - seconds clients may cache a card (default 300). Cards
      also carry an `ETag`.
    * `:push_notifications` - set `false` to turn push notifications off for
      this mount, even for agents that support them
    * `:extended_card` - set `false` to turn extended agent cards off for this
      mount
    * `:keepalive` - milliseconds between keepalive comments on an idle
      stream (default 15 seconds). Lower it to stay under a proxy's idle
      timeout.
    * `:max_request_size` - the largest body read, in bytes, when no
      `Plug.Parsers` ran before this plug
    * `:origins`, `:validate_origin`, `:hosts` - as in `Phantom.Plug`

  ## Telemetry

  Each request, on either binding, is a `[:phantom, :a2a, :dispatch]`
  telemetry span:

    * `:start` with metadata `~w[router agent_id method params session trace_context]a`
    * `:stop` with the same metadata plus `:result`: `{:ok, result}`,
      `{:error, %Phantom.A2A.Error{}}`, or `:stream` for a streamed response,
      whose span lasts until the stream closes
    * `:exception` with the metadata plus `~w[kind reason stacktrace]a`

  `:trace_context` holds the W3C `traceparent`, `tracestate`, and `baggage`
  headers the client sent. Push deliveries are spans too; see
  `Phantom.A2A.Push`.

  Defaults:

  ```elixir
  #{inspect(@default_opts, pretty: true)}
  ```
  """

  @behaviour Plug

  import Plug.Conn

  alias Phantom.A2A
  alias Phantom.A2A.{Context, Error, Events, Message, PushConfig, Task, TaskRef, TaskStatus}

  @protocol_version "1.0"
  @terminal_states ~w[completed failed canceled rejected]a

  @impl Plug
  def init(opts) do
    @default_opts
    |> Keyword.merge(opts)
    |> Map.new()
  end

  @impl Plug
  def call(conn, opts) do
    # Configuration for the router applies here too, as in `Phantom.Plug`.
    opts = Map.merge(opts, Map.new(Application.get_all_env(opts.router)))
    origin = conn |> get_req_header("origin") |> List.first()

    cond do
      not Phantom.Plug.valid_host?(conn.host, opts.hosts) ->
        send_error(conn, opts, nil, Error.invalid_request("Host not allowed"), 403)

      not Phantom.Plug.valid_origin?(origin, opts) ->
        send_error(conn, opts, nil, Error.invalid_request("Origin not allowed"), 403)

      true ->
        route(conn, opts)
    end
  end

  defp route(
         %Plug.Conn{method: "GET", path_info: [".well-known", "agent-card.json"]} = conn,
         opts
       ) do
    with id when is_binary(id) <- opts.router.__phantom__(:info).a2a[:well_known],
         {:ok, %{params?: false} = route, _params} <-
           Phantom.Router.A2A.match(opts.router, String.split(id, "/")) do
      serve_card(conn, opts, static_agent(route), opts.mount || "")
    else
      _ -> not_found(conn, opts)
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: path_info} = conn, opts) do
    with {segments, ["agent-card.json"]} <- Enum.split(path_info, -1),
         {:ok, route, params} <- Phantom.Router.A2A.match(opts.router, segments) do
      card_for(conn, opts, route, segments, params)
    else
      _ -> route_binding(conn, opts)
    end
  end

  defp route(conn, opts), do: route_binding(conn, opts)

  # An HTTP+JSON route, then a JSON-RPC request to the agent's path.
  defp route_binding(%Plug.Conn{method: method, path_info: segments} = conn, opts) do
    with true <- :http_json in opts.bindings,
         {:ok, rpc_method, path_params, rest} <- rest_route(method, Enum.reverse(segments)),
         {:ok, match, tenant} <- match_rest_agent(opts.router, Enum.reverse(rest)) do
      rest(conn, Map.put(opts, :binding, :http_json), match, rpc_method, path_params, tenant)
    else
      _ ->
        case {method, :jsonrpc in opts.bindings, Phantom.Router.A2A.match(opts.router, segments)} do
          {"POST", true, {:ok, route, params}} -> rpc(conn, opts, {route, segments, params})
          {method, _, _} when method in ~w[GET POST DELETE] -> not_found(conn, opts)
          _ -> send_error(conn, opts, nil, Error.invalid_request("Method not allowed"), 405)
        end
    end
  end

  # A static agent's card is public. A resolved agent's card needs the session.
  defp card_for(conn, opts, %{params?: false, resolver: nil} = route, _segments, _params),
    do: serve_card(conn, opts, static_agent(route), mount_path(conn))

  defp card_for(conn, opts, route, segments, params) do
    case open_agent(conn, opts, {route, segments, params}) do
      {:ok, _session, agent} -> serve_card(conn, opts, agent, mount_path(conn))
      :not_found -> not_found(conn, opts)
      %Plug.Conn{} = conn -> conn
    end
  end

  defp static_agent(route) do
    %{
      id: route.id,
      route: route,
      handler: route.handler,
      opts: route.opts,
      params: %{},
      state: nil,
      card: route.handler.__phantom_a2a__(:card)
    }
  end

  # Connect, check the allow-list, and resolve the agent for the session.
  defp open_agent(conn, opts, {route, segments, params}) do
    with {:ok, session} <- connect(conn, opts),
         :ok <- check_allowed(session, route, segments),
         {:ok, agent} <- resolve_agent(route, segments, params, session) do
      {:ok, session, agent}
    end
  end

  defp resolve_agent(%{resolver: nil} = route, _segments, _params, _session),
    do: {:ok, static_agent(route)}

  defp resolve_agent(route, segments, params, session) do
    case apply(route.handler, route.resolver, [params, session]) do
      {:ok, %A2A.Card{} = card, state} ->
        {:ok,
         %{
           static_agent(route)
           | id: Enum.join(segments, "/"),
             params: params,
             state: state,
             card: card
         }}

      {:error, :not_found} ->
        :not_found
    end
  end

  defp mount_path(%Plug.Conn{script_name: []}), do: ""
  defp mount_path(%Plug.Conn{script_name: script_name}), do: "/" <> Enum.join(script_name, "/")

  defp not_found(conn, opts),
    do: send_error(conn, opts, nil, Error.invalid_request("Not found"), 404)

  ## Agent cards

  defp serve_card(conn, opts, agent, mount) do
    body = conn |> card(opts, agent, mount) |> A2A.Card.to_json() |> JSON.encode!()
    etag = ~s("#{:sha256 |> :crypto.hash(body) |> Base.url_encode64(padding: false)}")
    conn = put_resp_header(conn, "cache-control", "public, max-age=#{opts.card_max_age}")

    if etag in get_req_header(conn, "if-none-match") do
      conn |> put_resp_header("etag", etag) |> send_resp(304, "")
    else
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  defp card(conn, opts, agent, mount) do
    info = opts.router.__phantom__(:info)
    card = agent.card
    base = URI.to_string(%URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port})

    %{
      card
      | version: card.version || info.version,
        provider: info.a2a[:provider],
        security_schemes: info.a2a[:security_schemes],
        security_requirements: info.a2a[:security_requirements],
        supported_interfaces:
          for(
            {binding, name} <- [jsonrpc: "JSONRPC", http_json: "HTTP+JSON"],
            binding in opts.bindings,
            do: %{
              "url" => "#{base}#{mount}/#{agent.id}",
              "protocolBinding" => name,
              "protocolVersion" => @protocol_version
            }
          ),
        capabilities:
          Phantom.Utils.remove_nils(%{
            "streaming" => not is_nil(opts.pubsub),
            "pushNotifications" => push_notifications?(agent, opts),
            "extensions" =>
              if(card.extensions != [],
                do: Enum.map(card.extensions, &A2A.Card.extension_to_json/1)
              ),
            "extendedAgentCard" => extended_card?(agent, opts)
          })
    }
  end

  ## HTTP+JSON

  # Routes from the `google.api.http` annotations of a2a.proto, matched on the
  # path's segments in reverse. What precedes them is the agent and tenant.
  defp rest_route("POST", ["message:send" | rest]), do: {:ok, "SendMessage", %{}, rest}
  defp rest_route("POST", ["message:stream" | rest]), do: {:ok, "SendStreamingMessage", %{}, rest}

  defp rest_route("GET", ["extendedAgentCard" | rest]),
    do: {:ok, "GetExtendedAgentCard", %{}, rest}

  defp rest_route("GET", ["tasks" | rest]), do: {:ok, "ListTasks", %{}, rest}

  defp rest_route("POST", ["pushNotificationConfigs", task_id, "tasks" | rest]),
    do: {:ok, "CreateTaskPushNotificationConfig", %{"taskId" => task_id}, rest}

  defp rest_route("GET", ["pushNotificationConfigs", task_id, "tasks" | rest]),
    do: {:ok, "ListTaskPushNotificationConfigs", %{"taskId" => task_id}, rest}

  defp rest_route("GET", [id, "pushNotificationConfigs", task_id, "tasks" | rest]),
    do: {:ok, "GetTaskPushNotificationConfig", %{"taskId" => task_id, "id" => id}, rest}

  defp rest_route("DELETE", [id, "pushNotificationConfigs", task_id, "tasks" | rest]),
    do: {:ok, "DeleteTaskPushNotificationConfig", %{"taskId" => task_id, "id" => id}, rest}

  defp rest_route("POST", [last, "tasks" | rest]) do
    case task_verb(last) do
      {id, "cancel"} -> {:ok, "CancelTask", %{"id" => id}, rest}
      # The method tables name POST; the proto names GET. Accept both.
      {id, "subscribe"} -> {:ok, "SubscribeToTask", %{"id" => id}, rest}
      _ -> :error
    end
  end

  defp rest_route("GET", [last, "tasks" | rest]) do
    case task_verb(last) do
      {id, "subscribe"} -> {:ok, "SubscribeToTask", %{"id" => id}, rest}
      _ -> {:ok, "GetTask", %{"id" => last}, rest}
    end
  end

  defp rest_route(_method, _segments), do: :error

  # "t1:cancel" -> {"t1", "cancel"}. Task IDs may contain ":", so split on the last.
  defp task_verb(segment) do
    case String.split(segment, ":") do
      [_id] -> :error
      parts -> {parts |> Enum.drop(-1) |> Enum.join(":"), List.last(parts)}
    end
  end

  # The agent's path, or the agent's path and a tenant.
  defp match_rest_agent(router, segments) do
    case Phantom.Router.A2A.match(router, segments) do
      {:ok, route, params} ->
        {:ok, {route, segments, params}, nil}

      :error when segments != [] ->
        {agent_segments, [tenant]} = Enum.split(segments, -1)

        with {:ok, route, params} <- Phantom.Router.A2A.match(router, agent_segments),
             do: {:ok, {route, agent_segments, params}, tenant}

      :error ->
        :error
    end
  end

  defp rest(conn, opts, match, method, path_params, tenant) do
    case rest_body(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.fetch_query_params(conn)

        params =
          body
          |> Map.merge(query_params(conn.query_params))
          |> Map.merge(path_params)
          |> then(&if tenant, do: Map.put(&1, "tenant", tenant), else: &1)

        # connect/2 sees the request as on JSON-RPC: its method and params.
        conn = %{conn | body_params: %{"method" => method, "params" => params}}
        serve(conn, opts, match, nil, method, params)

      {:error, :too_large, conn} ->
        send_error(conn, opts, nil, Error.invalid_request("Request too large"), 413)

      {:error, _reason, conn} ->
        send_error(conn, opts, nil, Error.parse_error(), 200)
    end
  end

  defp rest_body(%Plug.Conn{method: "POST"} = conn, opts) do
    case read_json(conn, opts) do
      {:ok, %{} = body, conn} -> {:ok, body, conn}
      {:ok, _not_an_object, conn} -> {:error, :invalid, conn}
      error -> error
    end
  end

  defp rest_body(conn, _opts), do: {:ok, %{}, conn}

  @integer_params ~w[pageSize historyLength]

  defp query_params(query) do
    Map.new(query, fn
      {key, value} when key in @integer_params ->
        case Integer.parse(value) do
          {integer, ""} -> {key, integer}
          _ -> {key, value}
        end

      {"includeArtifacts", value} ->
        {"includeArtifacts", value == "true"}

      pair ->
        pair
    end)
  end

  ## JSON-RPC

  defp rpc(conn, opts, match) do
    case read_json(conn, opts) do
      {:ok, body, conn} ->
        rpc(conn, opts, match, body)

      {:error, :too_large, conn} ->
        send_error(conn, opts, nil, Error.invalid_request("Request too large"), 413)

      {:error, _reason, conn} ->
        send_error(conn, opts, nil, Error.parse_error(), 200)
    end
  end

  # Without Plug.Parsers upstream, the body is read here, so invalid JSON gets
  # a JSON-RPC parse error instead of the parser's 400.
  defp read_json(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn, opts) do
    case read_body(conn, length: opts.max_request_size) do
      # An HTTP+JSON request may have no body, such as to cancel a task.
      {:ok, "", conn} when opts.binding == :http_json ->
        {:ok, %{}, conn}

      {:ok, raw, conn} ->
        case JSON.decode(raw) do
          {:ok, body} -> {:ok, body, put_body_params(conn, body)}
          {:error, reason} -> {:error, reason, conn}
        end

      {:more, _partial, conn} ->
        {:error, :too_large, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp read_json(conn, _opts), do: {:ok, conn.body_params, conn}

  # As `Plug.Parsers` would, so `c:Phantom.Router.connect/2` sees the body,
  # such as the request's `tenant`.
  defp put_body_params(conn, body) when is_map(body) do
    params = if is_map(conn.params) and not is_struct(conn.params), do: conn.params, else: %{}
    %{conn | body_params: body, params: Map.merge(params, body)}
  end

  defp put_body_params(conn, body), do: put_body_params(conn, %{"_json" => body})

  defp rpc(conn, opts, match, body) do
    case envelope(body) do
      {:ok, id, method, params} -> serve(conn, opts, match, id, method, params)
      :error -> send_error(conn, opts, nil, Error.invalid_request(), 200)
    end
  end

  # Serve a request of either binding, once it is a method and its params.
  defp serve(conn, opts, match, id, method, params) do
    with :ok <- check_version(conn),
         {:ok, session, agent} <- open_agent(conn, opts, match),
         {:ok, extensions} <- check_extensions(conn, agent) do
      conn = put_extensions_header(conn, extensions, agent)

      ctx = %Context{
        extensions: extensions,
        session: session,
        assigns: session.assigns,
        agent: Map.take(agent, [:id, :opts, :params, :state]),
        tenant: params["tenant"],
        metadata: params["metadata"]
      }

      # The public card, for GetExtendedAgentCard.
      opts = Map.put(opts, :card, fn -> card(conn, opts, agent, mount_path(conn)) end)

      meta = %{
        router: opts.router,
        agent_id: agent.id,
        method: method,
        params: params,
        session: session,
        trace_context: trace_context(conn)
      }

      try do
        :telemetry.span([:phantom, :a2a, :dispatch], meta, fn ->
          result = dispatch(method, params, agent, ctx, opts)
          conn = respond(conn, id, result, opts)
          {conn, %{}, Map.put(meta, :result, telemetry_result(result))}
        end)
      rescue
        exception ->
          send_error(conn, opts, id, Error.internal_error(), 200)
          reraise exception, __STACKTRACE__
      end
    else
      %Error{} = error -> send_error(conn, opts, id, error, 200)
      %Plug.Conn{} = conn -> conn
      :not_found -> not_found(conn, opts)
    end
  end

  defp check_extensions(conn, agent) do
    requested =
      conn
      |> get_req_header("a2a-extensions")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.find(agent.card.extensions, &(&1[:required] && &1.uri not in requested)) do
      nil -> {:ok, requested}
      extension -> Error.extension_support_required(extension.uri)
    end
  end

  # Name the requested extensions the agent supports, so the client knows
  # which ones apply.
  defp put_extensions_header(conn, requested, agent) do
    supported = for %{uri: uri} <- agent.card.extensions, uri in requested, do: uri

    if supported == [],
      do: conn,
      else: put_resp_header(conn, "a2a-extensions", Enum.join(supported, ", "))
  end

  # W3C Trace Context, as A2A clients send it: in HTTP headers.
  defp trace_context(conn) do
    for name <- ~w[traceparent tracestate baggage]a,
        [value | _] <- [get_req_header(conn, Atom.to_string(name))],
        into: %{},
        do: {name, value}
  end

  defp telemetry_result({:stream, _ref, _start}), do: :stream
  defp telemetry_result(result), do: result

  defp envelope(%{"jsonrpc" => "2.0", "method" => method} = body) when is_binary(method) do
    case Map.get(body, "params", %{}) do
      %{} = params -> {:ok, body["id"], method, params}
      _ -> :error
    end
  end

  defp envelope(_body), do: :error

  # A missing header means version 0.3, which this server doesn't speak.
  defp check_version(conn) do
    version = conn |> get_req_header("a2a-version") |> List.first("0.3")

    case version |> String.split(".") |> hd() |> String.trim() do
      "1" -> :ok
      _ -> Error.version_not_supported(version)
    end
  end

  defp connect(conn, opts) do
    session =
      Phantom.Session.new(nil,
        router: opts.router,
        pubsub: opts.pubsub,
        pid: self(),
        transport_pid: conn.owner
      )

    case opts.router.connect(session, conn) do
      {:ok, %Phantom.Session{} = session} ->
        {:ok, session}

      {status, info} when status in [401, :unauthorized] ->
        info = if is_map(info), do: Phantom.Plug.www_authenticate(info), else: info

        conn
        |> put_resp_header("www-authenticate", info)
        |> send_error(opts, nil, Error.invalid_request("Unauthorized"), 401)

      {status, message} when status in [403, :forbidden] ->
        send_error(conn, opts, nil, Error.invalid_request(message), 403)

      {status, message} when status in [404, :not_found] ->
        send_error(conn, opts, nil, Error.invalid_request(message), 404)

      {:error, reason} ->
        send_error(
          conn,
          opts,
          nil,
          Error.invalid_request("Connection failed: #{inspect(reason)}"),
          400
        )
    end
  end

  defp check_allowed(%Phantom.Session{allowed_agents: nil}, _route, _segments), do: :ok

  defp check_allowed(%Phantom.Session{allowed_agents: allowed}, route, segments) do
    if route.id in allowed or Enum.join(segments, "/") in allowed, do: :ok, else: :not_found
  end

  defp respond(conn, id, {:stream, ref, start}, opts) do
    # Subscribe before the work can start, so no event is missed.
    A2A.subscribe(ref)

    try do
      case start.() do
        {:ok, events, task} -> conn |> start_stream() |> stream(id, events, task, opts)
        {:error, %Error{} = error} -> send_error(conn, opts, id, error, 200)
      end
    after
      A2A.unsubscribe(ref)
    end
  end

  defp respond(conn, _id, {:ok, nil}, %{binding: :http_json}), do: send_resp(conn, 200, "")

  defp respond(conn, _id, {:ok, result}, %{binding: :http_json} = opts),
    do: send_json(conn, 200, result, opts)

  defp respond(conn, id, {:ok, result}, _opts),
    do: send_json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp respond(conn, id, {:error, %Error{} = error}, opts),
    do: send_error(conn, opts, id, error, 200)

  # On JSON-RPC, protocol errors are HTTP 200; on HTTP+JSON, each error has
  # its HTTP status. An explicit status, such as 401, applies to both.
  defp send_error(conn, opts, id, error, status) do
    send_json(
      conn,
      error_status(error, status, opts),
      error_payload(id, error, status, opts),
      opts
    )
  end

  defp error_status(error, 200, %{binding: :http_json}), do: Error.http_status(error)
  defp error_status(_error, status, _opts), do: status

  defp error_payload(_id, error, status, %{binding: :http_json} = opts),
    do: Error.to_status_json(error, error_status(error, status, opts))

  defp error_payload(id, error, _status, _opts), do: error_body(id, error)

  defp error_body(id, error),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => Error.to_json(error)}

  defp send_json(conn, status, body, opts \\ %{}) do
    content_type =
      if opts[:binding] == :http_json, do: "application/a2a+json", else: "application/json"

    conn
    |> put_resp_content_type(content_type)
    |> send_resp(status, JSON.encode!(body))
  end

  ## Methods

  defp dispatch("SendMessage", params, agent, ctx, opts) do
    with {:ok, ctx} <- prepare_send(params, agent, ctx, opts) do
      A2A.subscribe(ctx.task_ref)

      try do
        case handle_message(agent, ctx) do
          {:ok, %Message{} = message} ->
            {:ok, %{"message" => Message.to_json(message)}}

          {:ok, %Task{} = task} ->
            with {:ok, task} <- await(task, ctx, opts) do
              {:ok,
               %{"task" => Task.to_json(task, history_length: ctx.configuration["historyLength"])}}
            end

          error ->
            error
        end
      after
        A2A.unsubscribe(ctx.task_ref)
      end
    end
  end

  defp dispatch("SendStreamingMessage", params, agent, ctx, opts) do
    with :ok <- require_streaming(opts),
         {:ok, ctx} <- prepare_send(params, agent, ctx, opts) do
      {:stream, ctx.task_ref,
       fn ->
         case handle_message(agent, ctx) do
           {:ok, %Message{} = message} -> {:ok, [message], nil}
           {:ok, %Task{} = task} -> {:ok, [task], task}
           error -> error
         end
       end}
    end
  end

  defp dispatch("SubscribeToTask", %{"id" => id}, agent, ctx, opts) when is_binary(id) do
    with :ok <- require_streaming(opts) do
      ctx = %{ctx | task_ref: task_ref(id, agent, opts)}

      {:stream, ctx.task_ref,
       fn ->
         case existing_task(id, agent, ctx, allow_terminal: true) do
           {:ok, %Task{status: %{state: state}}} when state in @terminal_states ->
             {:error, Error.unsupported_operation("Task #{id} is already finished")}

           {:ok, task} ->
             {:ok, [task], task}

           error ->
             error
         end
       end}
    end
  end

  defp dispatch("ListTasks", params, agent, ctx, _opts) do
    with {:ok, filter} <- list_filter(params),
         {:ok, page} <- list_tasks(agent, filter, ctx) do
      opts = [
        history_length: params["historyLength"],
        include_artifacts: params["includeArtifacts"] == true
      ]

      {:ok,
       %{
         "tasks" => Enum.map(page.tasks, &Task.to_json(&1, opts)),
         "nextPageToken" => Map.get(page, :next_page_token) || "",
         "pageSize" => filter.page_size,
         "totalSize" => Map.get(page, :total_size) || length(page.tasks)
       }}
    end
  end

  defp dispatch("GetTask", %{"id" => id} = params, agent, ctx, opts) when is_binary(id) do
    ctx = %{ctx | task_ref: task_ref(id, agent, opts)}

    with {:ok, task} <- existing_task(id, agent, ctx, allow_terminal: true) do
      {:ok, Task.to_json(task, history_length: params["historyLength"])}
    end
  end

  defp dispatch("CancelTask", %{"id" => id}, agent, ctx, opts) when is_binary(id) do
    ctx = %{ctx | task_ref: task_ref(id, agent, opts)}

    with {:ok, task} <- existing_task(id, agent, ctx, allow_terminal: true) do
      cancel(task, agent, %{ctx | task_ref: %{ctx.task_ref | context_id: task.context_id}})
    end
  end

  defp dispatch(method, _params, _agent, _ctx, _opts)
       when method in ~w[GetTask CancelTask SubscribeToTask],
       do: {:error, Error.invalid_params("id is required")}

  defp dispatch("GetExtendedAgentCard", _params, agent, ctx, opts) do
    if extended_card?(agent, opts) do
      case agent.handler.extended_card(opts.card.(), ctx) do
        {:ok, %A2A.Card{} = card} -> {:ok, A2A.Card.to_json(card)}
        {:error, %Error{} = error} -> {:error, error}
        _other -> {:error, Error.invalid_agent_response()}
      end
    else
      {:error, Error.unsupported_operation("Extended agent cards are not supported")}
    end
  end

  defp dispatch(
         "CreateTaskPushNotificationConfig",
         %{"taskId" => task_id} = params,
         agent,
         ctx,
         opts
       )
       when is_binary(task_id) do
    with {:ok, ctx} <- push_task(task_id, agent, ctx, opts),
         {:ok, config} <- create_push_config(params, agent, ctx, opts) do
      {:ok, PushConfig.to_json(config)}
    end
  end

  defp dispatch(
         "GetTaskPushNotificationConfig",
         %{"taskId" => task_id, "id" => id},
         agent,
         ctx,
         opts
       )
       when is_binary(task_id) and is_binary(id) do
    with {:ok, ctx} <- push_task(task_id, agent, ctx, opts) do
      case agent.handler.get_push_config(task_id, id, ctx) do
        {:ok, %PushConfig{} = config} -> {:ok, PushConfig.to_json(config)}
        {:error, :not_found} -> {:error, Error.push_config_not_found(id)}
        {:error, %Error{} = error} -> {:error, error}
        _other -> {:error, Error.invalid_agent_response()}
      end
    end
  end

  defp dispatch(
         "ListTaskPushNotificationConfigs",
         %{"taskId" => task_id} = params,
         agent,
         ctx,
         opts
       )
       when is_binary(task_id) do
    with {:ok, ctx} <- push_task(task_id, agent, ctx, opts),
         {:ok, page_size} <- page_size(params["pageSize"]) do
      case agent.handler.list_push_configs(task_id, ctx) do
        {:ok, configs} when is_list(configs) ->
          offset = page_offset(params["pageToken"])
          configs = Enum.sort_by(configs, & &1.id)
          next = offset + page_size

          {:ok,
           %{
             "configs" =>
               configs |> Enum.slice(offset, page_size) |> Enum.map(&PushConfig.to_json/1),
             "nextPageToken" => if(next < length(configs), do: Integer.to_string(next), else: "")
           }}

        {:error, %Error{} = error} ->
          {:error, error}

        _other ->
          {:error, Error.invalid_agent_response()}
      end
    end
  end

  defp dispatch(
         "DeleteTaskPushNotificationConfig",
         %{"taskId" => task_id, "id" => id},
         agent,
         ctx,
         opts
       )
       when is_binary(task_id) and is_binary(id) do
    with {:ok, ctx} <- push_task(task_id, agent, ctx, opts) do
      case agent.handler.delete_push_config(task_id, id, ctx) do
        :ok -> {:ok, nil}
        {:error, %Error{} = error} -> {:error, error}
        _other -> {:error, Error.invalid_agent_response()}
      end
    end
  end

  defp dispatch(method, _params, agent, _ctx, opts)
       when method in ~w[CreateTaskPushNotificationConfig GetTaskPushNotificationConfig
                         ListTaskPushNotificationConfigs DeleteTaskPushNotificationConfig] do
    with :ok <- require_push(agent, opts),
         do: {:error, Error.invalid_params("taskId is required")}
  end

  defp dispatch(method, _params, _agent, _ctx, _opts),
    do: {:error, Error.method_not_found(method)}

  defp prepare_send(params, agent, ctx, opts) do
    with {:ok, message} <- decode_message(params["message"]),
         :ok <- check_media_types(message, agent),
         {:ok, stored} <- existing_task(message.task_id, agent, ctx),
         {:ok, context_id} <- context_id(message, stored) do
      task_id = if stored, do: stored.id, else: A2A.generate_id()

      ctx = %{
        ctx
        | message: %{message | context_id: context_id},
          task_ref: %{task_ref(task_id, agent, opts) | context_id: context_id},
          context_id: context_id,
          configuration: params["configuration"] || %{}
      }

      with :ok <-
             inline_push_config(ctx.configuration["taskPushNotificationConfig"], agent, ctx, opts),
           do: {:ok, ctx}
    end
  end

  # A config sent with the message is saved before the work starts, so no
  # update is missed.
  defp inline_push_config(nil, _agent, _ctx, _opts), do: :ok

  defp inline_push_config(json, agent, ctx, opts) do
    json = Map.put(json, "taskId", ctx.task_ref.task_id)

    with :ok <- require_push(agent, opts),
         {:ok, _config} <- create_push_config(json, agent, ctx, opts),
         do: :ok
  end

  defp push_task(task_id, agent, ctx, opts) do
    ctx = %{ctx | task_ref: task_ref(task_id, agent, opts)}

    with :ok <- require_push(agent, opts),
         {:ok, task} <- existing_task(task_id, agent, ctx, allow_terminal: true),
         do: {:ok, %{ctx | task_ref: %{ctx.task_ref | context_id: task.context_id}}}
  end

  defp require_push(agent, opts) do
    if push_notifications?(agent, opts),
      do: :ok,
      else: {:error, Error.push_notification_not_supported()}
  end

  defp extended_card?(agent, opts),
    do: opts.extended_card and agent.handler.__phantom_a2a__(:extended_card)

  defp push_notifications?(agent, opts),
    do: opts.push_notifications and agent.handler.__phantom_a2a__(:push_notifications)

  defp create_push_config(json, agent, ctx, opts) do
    allow_private? = opts.router.__phantom__(:info).a2a[:allow_private_push_urls] == true

    with {:ok, config} <- decode_push_config(json),
         :ok <- validate_push_url(config.url, allow_private?) do
      config = %{config | id: config.id || A2A.generate_id()}

      case agent.handler.create_push_config(config, ctx) do
        {:ok, %PushConfig{} = config} -> {:ok, config}
        {:error, %Error{} = error} -> {:error, error}
        _other -> {:error, Error.invalid_agent_response()}
      end
    end
  end

  defp decode_push_config(json) do
    case PushConfig.from_json(json) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, Error.invalid_params(reason)}
    end
  end

  defp validate_push_url(url, allow_private?) do
    case A2A.Push.validate_url(url, allow_private_networks: allow_private?) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.invalid_params("Push notification url #{reason}")}
    end
  end

  defp page_offset(token) when is_binary(token) do
    case Integer.parse(token) do
      {offset, ""} when offset >= 0 -> offset
      _invalid -> 0
    end
  end

  defp page_offset(_token), do: 0

  defp task_ref(task_id, agent, opts),
    do: %TaskRef{pubsub: opts.pubsub, router: opts.router, agent_id: agent.id, task_id: task_id}

  defp handle_message(agent, ctx) do
    case agent.handler.handle_message(ctx.message, ctx) do
      {:reply, %Message{} = message, _ctx} ->
        {:ok, %{message | context_id: message.context_id || ctx.context_id}}

      {:reply, %Task{} = task, _ctx} ->
        {:ok, task}

      {:error, %Error{} = error, _ctx} ->
        {:error, error}

      _other ->
        {:error, Error.invalid_agent_response()}
    end
  end

  defp require_streaming(%{pubsub: nil}),
    do: {:error, Error.unsupported_operation("Streaming is not supported")}

  defp require_streaming(_opts), do: :ok

  defp list_filter(params) do
    with {:ok, page_size} <- page_size(params["pageSize"]),
         {:ok, status} <- list_status(params["status"]),
         {:ok, after_time} <- timestamp(params["statusTimestampAfter"]) do
      {:ok,
       %{
         context_id: non_empty(params["contextId"]),
         status: status,
         page_size: page_size,
         page_token: non_empty(params["pageToken"]),
         status_timestamp_after: after_time
       }}
    end
  end

  defp page_size(nil), do: {:ok, 50}
  defp page_size(size) when is_integer(size) and size in 1..100, do: {:ok, size}
  defp page_size(_size), do: {:error, Error.invalid_params("pageSize must be from 1 to 100")}

  defp list_status(status) when status in [nil, "", "TASK_STATE_UNSPECIFIED"], do: {:ok, nil}

  defp list_status(status) do
    case TaskStatus.state_from_json(status) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, Error.invalid_params("unknown status #{inspect(status)}")}
    end
  end

  defp timestamp(nil), do: {:ok, nil}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _error ->
        {:error, Error.invalid_params("statusTimestampAfter must be an ISO 8601 timestamp")}
    end
  end

  defp timestamp(_value),
    do: {:error, Error.invalid_params("statusTimestampAfter must be an ISO 8601 timestamp")}

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp list_tasks(agent, filter, ctx) do
    case agent.handler.list_tasks(filter, ctx) do
      {:ok, %{tasks: tasks} = page} when is_list(tasks) -> {:ok, page}
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.invalid_agent_response()}
    end
  end

  defp decode_message(json) do
    case Message.from_json(json) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, Error.invalid_params(reason)}
    end
  end

  defp check_media_types(message, agent) do
    modes = agent.card.default_input_modes

    if Enum.all?(message.parts, &(&1.media_type in [nil, ""] or &1.media_type in modes)),
      do: :ok,
      else: {:error, Error.content_type_not_supported()}
  end

  defp existing_task(task_id, agent, ctx, opts \\ [])
  defp existing_task(nil, _agent, _ctx, _opts), do: {:ok, nil}

  defp existing_task(task_id, agent, ctx, opts) do
    case agent.handler.get_task(task_id, ctx) do
      {:ok, %Task{status: %{state: state}} = task} ->
        if Events.terminal?(state) and not Keyword.get(opts, :allow_terminal, false),
          do: {:error, Error.unsupported_operation("Task #{task_id} is already finished")},
          else: {:ok, task}

      {:error, :not_found} ->
        {:error, Error.task_not_found(task_id)}

      _other ->
        {:error, Error.invalid_agent_response()}
    end
  end

  # Canceling again is a no-op; other finished tasks can't be canceled.
  defp cancel(%Task{status: %{state: :canceled}} = task, _agent, _ctx),
    do: {:ok, Task.to_json(task)}

  defp cancel(%Task{id: id, status: %{state: state}} = task, agent, ctx) do
    if Events.terminal?(state) do
      {:error, Error.task_not_cancelable(id)}
    else
      case agent.handler.cancel_task(task, ctx) do
        {:ok, %Task{} = task} -> {:ok, Task.to_json(task)}
        {:error, :not_cancelable} -> {:error, Error.task_not_cancelable(id)}
        _other -> {:error, Error.invalid_agent_response()}
      end
    end
  end

  defp context_id(%Message{context_id: nil}, nil), do: {:ok, A2A.generate_id()}
  defp context_id(%Message{context_id: context_id}, nil), do: {:ok, context_id}
  defp context_id(%Message{context_id: nil}, %Task{context_id: context_id}), do: {:ok, context_id}
  defp context_id(%Message{context_id: id}, %Task{context_id: id}), do: {:ok, id}

  defp context_id(%Message{context_id: requested}, %Task{} = task),
    do: {:error, Error.invalid_params("contextId #{requested} does not match task #{task.id}")}

  # Wait for published events until the task finishes or needs the client,
  # unless the client asked to return at once or there is no pubsub to wait on.
  defp await(task, ctx, opts) do
    cond do
      settled?(task) or ctx.configuration["returnImmediately"] == true or is_nil(opts.pubsub) ->
        {:ok, task}

      true ->
        await_events(task, System.monotonic_time(:millisecond) + opts.blocking_timeout)
    end
  end

  defp await_events(task, deadline) do
    receive do
      {:phantom_a2a_event, event} ->
        case follow(task, event) do
          :seen -> await_events(task, deadline)
          {:ok, task} -> if settled?(task), do: {:ok, task}, else: await_events(task, deadline)
          {:error, :unknown_artifact} -> {:error, Error.invalid_agent_response()}
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:ok, task}
    end
  end

  # Apply a published event to this request's copy of the task, skipping
  # events the task already includes. Only numbered events move the copy's
  # sequence, as the agent's store numbers them.
  defp follow(task, event) do
    if Events.seen?(task, event) do
      :seen
    else
      with {:ok, applied, _event} <- Events.apply(task, event) do
        {:ok, if(numbered?(event), do: applied, else: %{applied | sequence: task.sequence})}
      end
    end
  end

  defp numbered?(%Message{}), do: false
  defp numbered?(%Task{sequence: sequence}), do: sequence > 0
  defp numbered?(%{sequence: sequence}), do: is_integer(sequence)

  ## SSE

  defp start_stream(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  # Send the first events, then each published event until the task settles.
  defp stream(conn, id, events, task, opts) do
    case send_events(conn, id, 1, events, opts) do
      {:ok, conn, _n} when is_nil(task) ->
        conn

      {:ok, conn, n} ->
        if settled?(task), do: conn, else: stream_events(conn, id, n, task, opts)

      {:error, conn} ->
        conn
    end
  end

  defp stream_events(conn, id, n, task, opts) do
    receive do
      {:phantom_a2a_event, event} ->
        event = fill_ids(event, task)

        with {:ok, task} <- follow(task, event),
             {:ok, conn, n} <- send_events(conn, id, n, [event], opts) do
          if settled?(task), do: conn, else: stream_events(conn, id, n, task, opts)
        else
          :seen ->
            stream_events(conn, id, n, task, opts)

          {:error, :unknown_artifact} ->
            error = Error.invalid_agent_response()
            {_result, conn} = send_sse(conn, n, error_payload(id, error, 200, opts))
            conn

          {:error, conn} ->
            conn
        end
    after
      opts.keepalive ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_events(conn, id, n, task, opts)
          {:error, _reason} -> conn
        end
    end
  end

  defp send_events(conn, _id, n, [], _opts), do: {:ok, conn, n}

  defp send_events(conn, id, n, [event | rest], opts) do
    body =
      case opts do
        %{binding: :http_json} -> A2A.event_to_json(event)
        _ -> %{"jsonrpc" => "2.0", "id" => id, "result" => A2A.event_to_json(event)}
      end

    case send_sse(conn, n, body) do
      {:ok, conn} -> send_events(conn, id, n + 1, rest, opts)
      {:error, conn} -> {:error, conn}
    end
  end

  defp send_sse(conn, n, body) do
    case chunk(conn, ["id: ", Integer.to_string(n), "\ndata: ", JSON.encode!(body), "\n\n"]) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, conn}
    end
  end

  defp fill_ids(%{task_id: nil} = event, task), do: fill_ids(%{event | task_id: task.id}, task)

  defp fill_ids(%{context_id: nil} = event, task),
    do: fill_ids(%{event | context_id: task.context_id}, task)

  defp fill_ids(event, _task), do: event

  defp settled?(%Task{status: %{state: state}}),
    do: Events.terminal?(state) or Events.interrupted?(state)
end

defmodule Phantom.A2A.Plug do
  @default_opts [
    pubsub: nil,
    origins: ["http://localhost:4000"],
    validate_origin: true,
    hosts: :all,
    mount: nil,
    blocking_timeout: :timer.seconds(60),
    card_max_age: 300,
    keepalive: :timer.seconds(15),
    max_request_size: 1_048_576
  ]

  @moduledoc """
  Serve a router's A2A agents over the JSON-RPC binding.

  Mount it under a path, and optionally serve one agent's card at the
  well-known path. Mount it without `Plug.Parsers`: it reads the body itself,
  so a request with invalid JSON gets the JSON-RPC parse error A2A requires
  rather than the parser's 400. A body that is already parsed is used as is.

      get "/.well-known/agent-card.json", Phantom.A2A.Plug,
        router: MyApp.MCP.Router,
        mount: "/a2a"

      scope "/a2a" do
        forward "/", Phantom.A2A.Plug, router: MyApp.MCP.Router, pubsub: MyApp.PubSub
      end

  Each `agent "research", ...` route in the router is then served at:

    * `GET /a2a/research/agent-card.json` - the agent's card
    * `POST /a2a/research` - JSON-RPC requests

  The well-known path serves the card of the agent named by the router's
  `a2a: [well_known: "research"]` option.

  Requests must send an `A2A-Version` header for version 1. Each request
  calls `c:Phantom.Router.connect/2` with the conn, its JSON-RPC request in
  `conn.body_params`, and agents excluded with `Phantom.Session.allow_agents/2`
  are not found. Cards are public.

  ## Options

    * `:router` - the `Phantom.Router` (required)
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
    * `:keepalive` - milliseconds between keepalive comments on an idle
      stream (default 15 seconds). Lower it to stay under a proxy's idle
      timeout.
    * `:max_request_size` - the largest body read, in bytes, when no
      `Plug.Parsers` ran before this plug
    * `:origins`, `:validate_origin`, `:hosts` - as in `Phantom.Plug`

  Defaults:

  ```elixir
  #{inspect(@default_opts, pretty: true)}
  ```
  """

  @behaviour Plug

  import Plug.Conn

  alias Phantom.A2A
  alias Phantom.A2A.{Context, Error, Events, Message, Task, TaskRef, TaskStatus}

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
        send_json(conn, 403, error_body(nil, Error.invalid_request("Host not allowed")))

      not Phantom.Plug.valid_origin?(origin, opts) ->
        send_json(conn, 403, error_body(nil, Error.invalid_request("Origin not allowed")))

      true ->
        route(conn, opts)
    end
  end

  defp route(
         %Plug.Conn{method: "GET", path_info: [".well-known", "agent-card.json"]} = conn,
         opts
       ) do
    case opts.router.__phantom__(:info).a2a[:well_known] do
      nil ->
        not_found(conn)

      id ->
        serve_card(conn, opts, find_agent(opts.router, String.split(id, "/")), opts.mount || "")
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: path_info} = conn, opts) do
    case Enum.split(path_info, -1) do
      {segments, ["agent-card.json"]} ->
        serve_card(conn, opts, find_agent(opts.router, segments), mount_path(conn))

      _ ->
        not_found(conn)
    end
  end

  defp route(%Plug.Conn{method: "POST", path_info: segments} = conn, opts) do
    case find_agent(opts.router, segments) do
      nil -> not_found(conn)
      agent -> rpc(conn, opts, agent)
    end
  end

  defp route(conn, _opts),
    do: send_json(conn, 405, error_body(nil, Error.invalid_request("Method not allowed")))

  defp find_agent(router, segments) do
    Enum.find(router.__phantom__(:info).agents, &(&1.segments == segments))
  end

  defp mount_path(%Plug.Conn{script_name: []}), do: ""
  defp mount_path(%Plug.Conn{script_name: script_name}), do: "/" <> Enum.join(script_name, "/")

  defp not_found(conn),
    do: send_json(conn, 404, error_body(nil, Error.invalid_request("Not found")))

  ## Agent cards

  defp serve_card(conn, _opts, nil, _mount), do: not_found(conn)

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
    card = agent.handler.__phantom_a2a__(:card)
    base = URI.to_string(%URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port})

    %{
      card
      | version: card.version || info.version,
        provider: info.a2a[:provider],
        security_schemes: info.a2a[:security_schemes],
        security_requirements: info.a2a[:security_requirements],
        supported_interfaces: [
          %{
            "url" => "#{base}#{mount}/#{agent.id}",
            "protocolBinding" => "JSONRPC",
            "protocolVersion" => @protocol_version
          }
        ],
        capabilities: %{
          "streaming" => not is_nil(opts.pubsub),
          "pushNotifications" => false,
          "extendedAgentCard" => false
        }
    }
  end

  ## JSON-RPC

  defp rpc(conn, opts, agent) do
    case read_json(conn, opts) do
      {:ok, body, conn} ->
        rpc(conn, opts, agent, body)

      {:error, :too_large, conn} ->
        send_json(conn, 413, error_body(nil, Error.invalid_request("Request too large")))

      {:error, _reason, conn} ->
        send_json(conn, 200, error_body(nil, Error.parse_error()))
    end
  end

  # Without Plug.Parsers upstream, the body is read here, so invalid JSON gets
  # a JSON-RPC parse error instead of the parser's 400.
  defp read_json(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn, opts) do
    case read_body(conn, length: opts.max_request_size) do
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

  defp rpc(conn, opts, agent, body) do
    case envelope(body) do
      {:ok, id, method, params} ->
        with :ok <- check_version(conn),
             {:ok, session} <- connect(conn, opts),
             :ok <- check_allowed(session, agent) do
          ctx = %Context{
            session: session,
            assigns: session.assigns,
            agent: %{id: agent.id, opts: agent.opts},
            tenant: params["tenant"],
            metadata: params["metadata"]
          }

          try do
            respond(conn, id, dispatch(method, params, agent, ctx, opts), opts)
          rescue
            exception ->
              send_json(conn, 200, error_body(id, Error.internal_error()))
              reraise exception, __STACKTRACE__
          end
        else
          %Error{} = error -> send_json(conn, 200, error_body(id, error))
          %Plug.Conn{} = conn -> conn
          :not_found -> not_found(conn)
        end

      :error ->
        send_json(conn, 200, error_body(nil, Error.invalid_request()))
    end
  end

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
        |> send_json(401, error_body(nil, Error.invalid_request("Unauthorized")))

      {status, message} when status in [403, :forbidden] ->
        send_json(conn, 403, error_body(nil, Error.invalid_request(message)))

      {status, message} when status in [404, :not_found] ->
        send_json(conn, 404, error_body(nil, Error.invalid_request(message)))

      {:error, reason} ->
        send_json(
          conn,
          400,
          error_body(nil, Error.invalid_request("Connection failed: #{inspect(reason)}"))
        )
    end
  end

  defp check_allowed(%Phantom.Session{allowed_agents: nil}, _agent), do: :ok

  defp check_allowed(%Phantom.Session{allowed_agents: allowed}, agent) do
    if agent.id in allowed, do: :ok, else: :not_found
  end

  defp respond(conn, id, {:stream, ref, start}, opts) do
    # Subscribe before the work can start, so no event is missed.
    A2A.subscribe(ref)

    try do
      case start.() do
        {:ok, events, task} -> conn |> start_stream() |> stream(id, events, task, opts.keepalive)
        {:error, %Error{} = error} -> send_json(conn, 200, error_body(id, error))
      end
    after
      A2A.unsubscribe(ref)
    end
  end

  defp respond(conn, id, {:ok, result}, _opts),
    do: send_json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp respond(conn, id, {:error, %Error{} = error}, _opts),
    do: send_json(conn, 200, error_body(id, error))

  defp error_body(id, error),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => Error.to_json(error)}

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
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
      cancel(task, agent, ctx)
    end
  end

  defp dispatch(method, _params, _agent, _ctx, _opts)
       when method in ~w[GetTask CancelTask SubscribeToTask],
       do: {:error, Error.invalid_params("id is required")}

  defp dispatch("GetExtendedAgentCard", _params, _agent, _ctx, _opts),
    do: {:error, Error.unsupported_operation("Extended agent cards are not supported")}

  defp dispatch(method, _params, _agent, _ctx, _opts)
       when method in ~w[CreateTaskPushNotificationConfig GetTaskPushNotificationConfig
                         ListTaskPushNotificationConfigs DeleteTaskPushNotificationConfig],
       do: {:error, Error.push_notification_not_supported()}

  defp dispatch(method, _params, _agent, _ctx, _opts),
    do: {:error, Error.method_not_found(method)}

  defp prepare_send(params, agent, ctx, opts) do
    with {:ok, message} <- decode_message(params["message"]),
         :ok <- check_media_types(message, agent),
         {:ok, stored} <- existing_task(message.task_id, agent, ctx),
         {:ok, context_id} <- context_id(message, stored) do
      {:ok,
       %{
         ctx
         | message: %{message | context_id: context_id},
           task_ref: task_ref(if(stored, do: stored.id, else: A2A.generate_id()), agent, opts),
           context_id: context_id,
           configuration: params["configuration"] || %{}
       }}
    end
  end

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
    modes = agent.handler.__phantom_a2a__(:card).default_input_modes

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
        case Events.apply(task, event) do
          {:ok, task} -> if settled?(task), do: {:ok, task}, else: await_events(task, deadline)
          {:error, :unknown_artifact} -> {:error, Error.invalid_agent_response()}
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:ok, task}
    end
  end

  ## SSE

  defp start_stream(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  # Send the first events, then each published event until the task settles.
  defp stream(conn, id, events, task, keepalive) do
    case send_events(conn, id, 1, events) do
      {:ok, conn, _n} when is_nil(task) ->
        conn

      {:ok, conn, n} ->
        if settled?(task), do: conn, else: stream_events(conn, id, n, task, keepalive)

      {:error, conn} ->
        conn
    end
  end

  defp stream_events(conn, id, n, task, keepalive) do
    receive do
      {:phantom_a2a_event, event} ->
        event = fill_ids(event, task)

        with {:ok, task} <- Events.apply(task, event),
             {:ok, conn, n} <- send_events(conn, id, n, [event]) do
          if settled?(task), do: conn, else: stream_events(conn, id, n, task, keepalive)
        else
          {:error, :unknown_artifact} ->
            {_result, conn} = send_sse(conn, n, error_body(id, Error.invalid_agent_response()))
            conn

          {:error, conn} ->
            conn
        end
    after
      keepalive ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_events(conn, id, n, task, keepalive)
          {:error, _reason} -> conn
        end
    end
  end

  defp send_events(conn, _id, n, []), do: {:ok, conn, n}

  defp send_events(conn, id, n, [event | rest]) do
    body = %{"jsonrpc" => "2.0", "id" => id, "result" => A2A.event_to_json(event)}

    case send_sse(conn, n, body) do
      {:ok, conn} -> send_events(conn, id, n + 1, rest)
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

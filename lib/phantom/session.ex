defmodule Phantom.Session do
  @moduledoc """
  Represents the state of the MCP session. This is the state across the conversation
  and is the bridge between the various transports (HTTP, stdio) to persistence,
  even if stateless.
  """

  alias Phantom.Request

  @enforce_keys [:id]
  defstruct [
    :allowed_prompts,
    :allowed_resource_templates,
    :allowed_tools,
    :state,
    :elicit,
    :id,
    :last_event_id,
    :pid,
    :pubsub,
    :request,
    :router,
    :stream_fun,
    :tracker,
    :transport_pid,
    assigns: %{},
    client_info: %{},
    client_capabilities: %{
      roots: false,
      sampling: false,
      elicitation: false,
      ui: false
    },
    close_after_complete: true,
    requests: %{}
  ]

  @type t :: %__MODULE__{
          allowed_prompts: [String.t()],
          allowed_resource_templates: [String.t()],
          allowed_tools: [String.t()],
          state: term() | nil,
          elicit:
            (Phantom.Elicit.t(), timeout :: pos_integer() ->
               {:ok, map()} | :error | :timeout)
            | nil,
          assigns: map(),
          close_after_complete: boolean(),
          id: binary(),
          last_event_id: String.t() | nil,
          pid: pid() | nil,
          pubsub: module(),
          request: Phantom.Request.t() | nil,
          requests: map(),
          router: module(),
          stream_fun: fun(),
          client_info: map(),
          client_capabilities: %{
            elicitation: false | map(),
            sampling: false | map(),
            roots: false | map(),
            ui: false | map()
          },
          transport_pid: pid()
        }

  @elicitation_timeout to_timeout(minute: 5)

  @spec new(String.t() | nil, Keyword.t() | map) :: t()
  @doc """
  Builds a new session with the provided session ID.

  This is used for adapters such as `Phantom.Plug`. If a
  session ID is not provided, it will generate one using `UUIDv7`.
  """
  def new(session_id, opts \\ []) do
    struct!(__MODULE__, [id: session_id || UUIDv7.generate()] ++ opts)
  end

  @doc "Set an allow-list of usable Tools for the session"
  def allow_tools(%__MODULE__{} = session, tools) do
    %{session | allowed_tools: tools}
  end

  @doc "Set an allow-list of usable Resource Templates for the session"
  def allow_resource_templates(%__MODULE__{} = session, resource_templates) do
    %{session | allowed_resource_templates: resource_templates}
  end

  @doc "Set an allow-list of usable Prompts for the session"
  def allow_prompts(%__MODULE__{} = session, prompts) do
    %{session | allowed_prompts: prompts}
  end

  @doc "Fetch the current progress token if provided by the client"
  def progress_token(%__MODULE__{request: %{params: params}}) do
    params["_meta"]["progressToken"]
  end

  @doc """
  Elicit input from the client.

  Two call patterns, with protocol-aware defaults that preserve historical
  behavior:

  - **Inline blocking** (`:await` true, or default under legacy) — returns
    `{:ok, response}` where `response` is the client's JSON map (`"action"`
    and `"content"` keys), or `:not_supported` / `:timeout` / `:error`.
    Under legacy MCP protocols the call blocks via the open SSE stream;
    under MCP `2026-07-28` Phantom suspends the tool's Task, returns an
    `inputRequired` result to the client, and resumes the Task inline when
    the follow-up `tools/call` arrives (possibly on another node).

  - **Re-entry** (`:state` set, or default under stateless) — returns
    `{:input_required, elicit, state, session}`, a tagged tuple the
    dispatcher converts to an `inputRequired` result (stateless) or runs
    through the SSE elicit round-trip + handler re-invocation (legacy).
    The handler is *re-entered* with `session.state` populated to whatever
    you passed as `:state` (default `nil`). Structure the handler with a
    function-head clause that matches on `%Session{state: %{...}}`.

  Protocol-aware defaults — when neither `:await` nor `:state` is set:

  - Under legacy protocols (`≤ 2025-11-25`) the call defaults to inline
    blocking. Existing legacy code that pattern-matches `{:ok, response}`
    against `Session.elicit(session, elicit)` continues to work unchanged.
  - Under MCP `2026-07-28` (stateless core) the call defaults to re-entry
    with `state: nil`. Inline blocking under stateless requires explicit
    `await: true` because it can't be the default — code that relied on the
    implicit blocking under legacy would otherwise silently change semantics.

  Pick based on style preference:

      # Inline — the function continues after the response arrives
      def my_tool(_params, session) do
        {:ok, %{"choice" => c}} = Session.elicit(session, elicit, await: true)
        {:reply, Tool.text("got \#{c}"), session}
      end

      # Re-entry — the handler is invoked again with session.state populated
      def my_tool(%{"choice" => c}, %Session{state: %{step: :got_choice}} = session) do
        {:reply, Tool.text("got \#{c}"), session}
      end

      def my_tool(params, session) do
        Session.elicit(session, elicit, state: %{step: :got_choice})
      end

  Options:
    - `:await` — `true` to force inline blocking regardless of protocol
    - `:state` — value placed on `session.state` on re-entry; forces re-entry
      mode regardless of protocol
    - `:timeout` — max blocking time in ms (`:await` mode only; default: 5 minutes)
  """
  @spec elicit(t, Phantom.Elicit.t(), keyword()) ::
          {:ok, response :: map()}
          | {:input_required, Phantom.Elicit.t(), state :: term(), t}
          | :not_supported
          | :error
          | :timeout
  def elicit(session, elicitation, opts \\ []) do
    cond do
      # Explicit :await — force inline blocking on either protocol.
      Keyword.get(opts, :await, false) ->
        if stateless?(session) do
          stateless_await(session, elicitation, opts)
        else
          do_elicit(session, elicitation, opts)
        end

      # Explicit :state — force re-entry on either protocol.
      Keyword.has_key?(opts, :state) ->
        {:input_required, elicitation, opts[:state], session}

      # Protocol-aware default: stateless → re-entry, legacy → inline blocking.
      stateless?(session) ->
        {:input_required, elicitation, nil, session}

      true ->
        do_elicit(session, elicitation, opts)
    end
  end

  defp stateless_await(_session, elicitation, opts) do
    timeout = Keyword.get(opts, :timeout, @elicitation_timeout)
    ref_id = UUIDv7.generate()
    adopter = Process.get(:phantom_adopter)
    request_id = Process.get(:phantom_tool_request_id)

    if is_nil(adopter) or is_nil(request_id) do
      raise ArgumentError,
            "Session.elicit/3 with `await: true` must be called from within a tool handler"
    end

    send(adopter, {:phantom_await_elicit, ref_id, elicitation, self(), request_id})

    receive do
      {:phantom_elicit_response, ^ref_id, response, new_adopter, new_request_id} ->
        Process.put(:phantom_adopter, new_adopter)
        Process.put(:phantom_tool_request_id, new_request_id)
        response
    after
      timeout -> :timeout
    end
  end

  @doc """
  Whether the session's current request is using the MCP `2026-07-28`
  stateless-core protocol.
  """
  def stateless?(%__MODULE__{request: %{meta: meta}}) when is_map(meta),
    do: meta["protocolVersion"] == "2026-07-28"

  def stateless?(_), do: false

  defp do_elicit(session, elicitation, opts) do
    timeout = Keyword.get(opts, :timeout, @elicitation_timeout)

    capabilities =
      case session.client_capabilities[:elicitation] do
        false when is_function(session.elicit) -> %{}
        other -> other
      end

    with_elicitation_support(capabilities, elicitation, fn ->
      cond do
        # Fast path: called from within the stream-owner process
        # (e.g. a synchronous tool handler). The adapter-provided
        # `session.elicit` closure writes to the transport directly
        # and blocks in a receive.
        is_function(session.elicit) and self() == session.pid ->
          session.elicit.(elicitation, timeout)

        # Cross-process path: called from a Task spawned after the
        # tool returned `{:noreply, session}`. The captured conn in
        # the closure can only be written from the stream owner
        # (Bandit enforces this), so delegate to the session
        # GenServer which owns the stream.
        is_pid(session.pid) ->
          tool_call_id = session.request && session.request.id

          try do
            GenServer.call(
              session.pid,
              {:elicit, elicitation, tool_call_id},
              timeout + 1_000
            )
          catch
            :exit, {:timeout, _} -> :timeout
            :exit, _ -> :error
          end

        true ->
          :error
      end
    end)
  end

  defp with_elicitation_support(nil, _elicitation, _fun), do: :not_supported
  defp with_elicitation_support(false, _elicitation, _fun), do: :not_supported

  defp with_elicitation_support(capabilities, elicitation, fun) when is_map(capabilities) do
    if elicitation_mode_supported?(elicitation.mode, capabilities) do
      fun.()
    else
      :not_supported
    end
  end

  defp elicitation_mode_supported?(:form, _capabilities), do: true
  defp elicitation_mode_supported?(:url, capabilities), do: is_map_key(capabilities, "url")

  @doc "Convenience to elicit a URL mode interaction. Blocks until the client responds."
  @spec elicit_url(t, url :: String.t(), message :: String.t(), keyword()) ::
          {:ok, response :: map()} | :not_supported | :error | :timeout
  def elicit_url(session, url, message, opts \\ []) do
    elicit(
      session,
      Phantom.Elicit.url(%{
        message: message,
        url: url,
        elicitation_id: UUIDv7.generate()
      }),
      opts
    )
  end

  @spec assign(t(), atom(), any()) :: t()
  @doc "Assign state to the session."
  def assign(session, key, value) do
    %{session | assigns: Map.put(session.assigns, key, value)}
  end

  @doc "Assign state to the session."
  @spec assign(t(), map()) :: t()
  def assign(session, map) do
    %{session | assigns: Map.merge(session.assigns, Map.new(map))}
  end

  @doc """
  Subscribe the session to a resource.

  This is used by the MCP Router when the client requests to subscribe to the provided resource.
  """
  @spec subscribe_to_resource(t(), string_uri :: String.t()) :: :ok | :error
  def subscribe_to_resource(%__MODULE__{pubsub: nil}, _uri), do: :error

  def subscribe_to_resource(session, uri) do
    case Phantom.Tracker.get_session(session) do
      nil -> :error
      pid -> GenServer.cast(pid, {:subscribe_resource, uri})
    end
  end

  @doc """
  Unsubscribe the session to a resource.

  This is used by the MCP Router when the client requests to subscribe to the provided resource.
  """
  @spec unsubscribe_to_resource(t(), string_uri :: String.t()) :: :ok | :error
  def unsubscribe_to_resource(%__MODULE__{pubsub: nil}, _uri), do: :error

  def unsubscribe_to_resource(session, uri) do
    case Phantom.Tracker.get_session(session) do
      nil -> :error
      pid -> GenServer.cast(pid, {:unsubscribe_resource, uri})
    end
  end

  def list_resource_subscriptions(session) do
    case Phantom.Tracker.get_session(session) do
      nil -> []
      pid -> GenServer.call(pid, :list_resource_subscriptions)
    end
  end

  @doc """
  Sets the log level for the SSE stream.
  Sets both for the current request for async tasks and the SSE stream
  """
  @spec set_log_level(t(), Request.t(), String.t()) :: :ok
  def set_log_level(%__MODULE__{} = session, request, level) do
    case Phantom.Tracker.get_session(session) || session.pid do
      nil -> :error
      pid -> GenServer.cast(pid, {:set_log_level, request, level})
    end
  end

  @doc "Closes the connection for the session"
  @spec finish(t() | pid) :: :ok
  def finish(%__MODULE__{pid: pid}), do: finish(pid)
  def finish(pid) when is_pid(pid), do: GenServer.cast(pid, :finish)

  @doc """
  Sends response back to the stream

  This should likely be used in conjunction with:

  - `Phantom.Tool.response(payload)`
  - `Phantom.Resource.response(payload)`
  - `Phantom.Prompt.response(payload)`

  For example:

  ```elixir
  session_pid = session.pid
  request_id = request.id

  Task.async(fn ->
    Session.respond(
      session_pid,
      request_id,
      Phantom.Tool.audio(
        File.read!("priv/static/game-over.wav"),
        mime_type: "audio/wav"
      )
    )
  end)
  ```
  """
  def respond(%__MODULE__{pid: pid, request: %{id: request_id}}, payload),
    do: respond(pid, request_id, payload)

  @doc "See `respond/2`"
  def respond(%__MODULE__{pid: pid}, request_id, payload), do: respond(pid, request_id, payload)
  def respond(pid, %Request{id: id}, payload), do: respond(pid, id, payload)

  def respond(pid, request_id, payload) when is_pid(pid) do
    GenServer.cast(
      pid,
      {:respond, request_id,
       %{
         id: request_id,
         jsonrpc: "2.0",
         result: payload
       }}
    )
  end

  @doc """
  Send a JSON-RPC error response for a pending request.

  Used by async tool handlers (running in a Task) to finalize a request
  with a protocol-level error rather than a Tool.error result.
  """
  @spec respond_error(pid() | t(), Request.t() | String.t() | integer(), map()) :: :ok
  def respond_error(%__MODULE__{pid: pid}, request_id, error),
    do: respond_error(pid, request_id, error)

  def respond_error(pid, %Request{id: id}, error), do: respond_error(pid, id, error)

  def respond_error(pid, request_id, error) when is_pid(pid) do
    GenServer.cast(
      pid,
      {:respond, request_id,
       %{
         id: request_id,
         jsonrpc: "2.0",
         error: error
       }}
    )
  end

  @doc "Send a notification to the client"
  @spec notify(t | pid(), payload :: any()) :: :ok
  def notify(%__MODULE__{pid: pid}, payload), do: notify(pid, payload)

  def notify(pid, payload) when is_pid(pid) do
    GenServer.cast(pid, {:notify, payload})
  end

  @doc "Send a ping to the client"
  @spec ping(t | pid()) :: :ok
  def ping(%__MODULE__{pid: pid}), do: ping(pid)
  def ping(pid) when is_pid(pid), do: GenServer.cast(pid, :ping)

  @doc """
  Send a progress notification to the client

  the `progress` and `total` can be a integer or float, but must be ever-increasing.
  the `total` is optional.

  https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress
  """
  @spec notify_progress(t, number(), nil | number()) :: :ok
  def notify_progress(session, progress, total \\ nil)

  def notify_progress(%__MODULE__{pid: pid} = session, progress, total) do
    notify_progress(pid, progress_token(session), progress, total)
  end

  def notify_progress(pid, nil, _progress, _total), do: ping(pid)

  def notify_progress(pid, progress_token, progress, total) do
    GenServer.cast(pid, {:send, Request.notify_progress(progress_token, progress, total)})
  end

  @doc false
  def start_loop(opts) do
    session = Keyword.fetch!(opts, :session)
    timeout = Keyword.fetch!(opts, :timeout)
    opts = Keyword.put_new(opts, :log_level, 5)
    {cb, opts} = Keyword.pop(opts, :continue_fun)
    Process.set_label({__MODULE__, session.id})

    :gen_server.enter_loop(
      __MODULE__,
      [],
      Map.new(
        opts ++
          [
            timeout: timeout,
            last_activity: System.system_time()
          ]
      ),
      self(),
      {:continue, cb}
    )
  end

  @doc false
  def handle_continue(cb, state) do
    state = schedule_inactivity(Map.put(state, :timer, nil))

    if is_function(cb, 1) do
      maybe_finish(cb.(state))
    else
      {:noreply, state}
    end
  end

  @doc false
  def handle_call(:list_resource_subscriptions, _from, state) do
    {:reply, {:ok, Map.keys(state.subscriptions)}, state}
  end

  def handle_call({:elicit, elicitation, tool_call_id}, from, state) do
    cancel_inactivity(state)

    {request, ref} =
      Phantom.Elicit.prepare_request(state.session.id, tool_call_id, elicitation)

    caller = %{from: from, request_id: request.id}

    state =
      state
      |> Map.update(:elicitation_callers, %{ref => caller}, &Map.put(&1, ref, caller))
      |> Map.update(:pending_elicit_ids, %{request.id => ref}, &Map.put(&1, request.id, ref))
      |> state.stream_fun.(request.id, "message", Request.to_json(request))

    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  @doc false
  def handle_cast(:finish, state) do
    state = state.stream_fun.(state, nil, "closed", "finished")
    {:stop, {:shutdown, :closed}, state}
  end

  @doc false
  def handle_cast({:log, level, level_name, domain, payload}, state)
      when level <= state.log_level do
    cancel_inactivity(state)

    {:noreply,
     state
     |> state.stream_fun.(
       nil,
       "message",
       Request.notify(%{level: level_name, logger: domain, data: payload})
     )
     |> set_activity()
     |> schedule_inactivity()}
  end

  def handle_cast({:log, _level, _level_name, _domain, _payload}, state) do
    {:noreply, state}
  end

  def handle_cast(:ping, state) do
    cancel_inactivity(state)
    state = state.stream_fun.(state, nil, "message", Request.ping())
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast({:send, payload}, state) do
    cancel_inactivity(state)
    state = state.stream_fun.(state, nil, "message", payload)
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast({:respond, request_id, payload}, state) do
    cancel_inactivity(state)
    state = state.stream_fun.(state, request_id, "message", payload)
    requests = Map.delete(state.session.requests, request_id)
    state = put_in(state.session.requests, requests)
    Phantom.Tracker.untrack_in_flight(state.session.id, request_id)
    state = release_in_flight(state, request_id)
    maybe_finish(state)
  end

  def handle_cast({:subscribe_resource, uri}, state) do
    cancel_inactivity(state)
    Phantom.Tracker.subscribe_resource(uri)
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast({:unsubscribe_resource, uri}, state) do
    cancel_inactivity(state)
    Phantom.Tracker.unsubscribe_resource(uri)
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast({:resource_updated, uri}, state) do
    cancel_inactivity(state)
    state = state.stream_fun.(state, nil, "message", Request.resource_updated(%{uri: uri}))
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast(:tools_updated, state) do
    notify? = state.session.allowed_tools == nil

    if notify? do
      cancel_inactivity(state)
      state = state.stream_fun.(state, nil, "message", Request.tools_updated())
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:prompts_updated, state) do
    notify? = state.session.allowed_prompts == nil

    if notify? do
      cancel_inactivity(state)
      state = state.stream_fun.(state, nil, "message", Request.prompts_updated())
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:resources_updated, state) do
    notify? = state.session.allowed_resource_templates == nil

    if notify? do
      cancel_inactivity(state)
      state = state.stream_fun.(state, nil, "message", Request.resources_updated())
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:set_log_level, request, log_level}, state) do
    level_num =
      Keyword.fetch!(
        Phantom.ClientLogger.log_levels(),
        String.to_existing_atom(log_level)
      )

    state = state.stream_fun.(state, request.id, "message", %{})
    {:noreply, %{state | log_level: level_num}}
  end

  defp maybe_finish(state) do
    if Enum.any?(Map.keys(state.session.requests)) or not state.session.close_after_complete do
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      handle_cast(:finish, state)
    end
  end

  @doc false
  # eat this message since we send once the stream loop is over
  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}

  def handle_info({:phantom_elicitation_response, ref, response}, state) do
    case pop_in(state, [:elicitation_callers, ref]) do
      {nil, state} ->
        {:noreply, state}

      {%{from: from, request_id: request_id}, state} ->
        GenServer.reply(from, {:ok, response})
        state = forget_pending_elicit(state, request_id)
        {:noreply, state |> set_activity() |> schedule_inactivity()}
    end
  end

  def handle_info(
        {:phantom_await_elicit, ref_id, elicitation, task_pid, request_id},
        state
      ) do
    secret = state.session.router.__phantom__(:info)[:secret_key_base]

    if is_nil(secret) do
      __MODULE__.respond_error(
        self(),
        request_id,
        Request.internal_error("Stateless await requires :secret_key_base on the router")
      )

      {:noreply, state}
    else
      state_blob = Phantom.RequestState.encode({:__phantom_await__, ref_id}, secret)

      Phantom.Tracker.track_request(task_pid, ref_id, %{
        type: :pending_task,
        pid: task_pid
      })

      __MODULE__.respond(
        self(),
        request_id,
        Phantom.Tool.input_required(elicitation, state_blob)
      )

      {:noreply, state |> set_activity() |> schedule_inactivity()}
    end
  end

  def handle_info(:inactivity, state) do
    cond do
      not state.session.close_after_complete ->
        state = state.stream_fun.(state, nil, "message", Request.ping())
        {:noreply, state |> set_activity() |> schedule_inactivity()}

      System.system_time() - state.last_activity > state.timeout ->
        state = state.stream_fun.(state, nil, "closed", "inactivity")
        {:stop, {:shutdown, :closed}, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:phantom_dispatch, requests}, state) do
    cancel_inactivity(state)

    # Intercept elicitation responses locally before dispatching
    # to the router. When `Phantom.Tracker` isn't available (the
    # default for stdio), the router's response path can't route
    # back to the waiting `GenServer.call`. The local
    # `:pending_elicit_ids` map is populated when this GenServer
    # initiates an async elicitation via `handle_call({:elicit, ...})`.
    {elicit_responses, other} = partition_elicit_responses(requests, state)

    state = Enum.reduce(elicit_responses, state, &route_local_elicit_response/2)

    state =
      Enum.reduce(other, state, fn raw_request, state_acc ->
        case Request.build(raw_request) do
          {:ok, request} ->
            dispatch_stdio_request(request, state_acc)

          {:error, error} ->
            state_acc.stream_fun.(state_acc, error.id, "message", error.response)
        end
      end)

    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_info({:phantom_dispatch_error, :parse_error}, state) do
    cancel_inactivity(state)
    error = Request.error(nil, Request.parse_error("Parse error: Invalid JSON"))
    state = state.stream_fun.(state, nil, "message", error)
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_info({:phantom_reader_closed, reason}, state) do
    state.session.router.disconnect(state.session)
    state.session.router.terminate(state.session)

    :telemetry.execute(
      [:phantom, :stdio, :terminate],
      %{},
      %{session: state.session, router: state.session.router, reason: reason}
    )

    {:stop, {:shutdown, :eof}, state}
  end

  def handle_info(_what, state) do
    {:noreply, state}
  end

  # Methods that dispatch to user-defined handlers and may have
  # side effects (including elicitation). Other methods are
  # idempotent, so double-dispatch is harmless and we skip the
  # dedup overhead for them.
  @dedupable_methods ~w[tools/call prompts/get]

  # Notifications have no id; dispatch but don't write a response
  defp dispatch_stdio_request(%Request{id: nil} = request, state) do
    case state.session.router.dispatch_method([
           request.method,
           request.params,
           request,
           state.session
         ]) do
      {:reply, _result, %__MODULE__{} = session} -> put_in(state.session, session)
      {:noreply, %__MODULE__{} = session} -> put_in(state.session, session)
      {:error, _error, %__MODULE__{} = session} -> put_in(state.session, session)
      _ -> state
    end
  rescue
    _ -> state
  end

  defp dispatch_stdio_request(
         %Request{method: method, id: request_id} = request,
         state
       )
       when method in @dedupable_methods and not is_nil(request_id) do
    if request_in_flight?(state, request_id) do
      error = Request.error(request_id, Request.duplicate_request())
      state.stream_fun.(state, request_id, "message", error)
    else
      state
      |> claim_in_flight(request_id)
      |> do_dispatch_stdio_request(request)
    end
  end

  defp dispatch_stdio_request(request, state), do: do_dispatch_stdio_request(state, request)

  defp do_dispatch_stdio_request(state, request) do
    stream_fun = state.stream_fun

    try do
      case state.session.router.dispatch_method([
             request.method,
             request.params,
             request,
             state.session
           ]) do
        {:noreply, %__MODULE__{} = session} ->
          # In-flight claim stays held until `Session.respond/2`
          # casts back to this GenServer and untracks.
          requests = Map.put(session.requests, request.id, request.response)
          put_in(state.session, %{session | requests: requests})

        {:reply, nil, %__MODULE__{} = session} ->
          state
          |> put_session(session)
          |> release_in_flight(request.id)

        {:reply, result, %__MODULE__{} = session} ->
          request = Request.result(request, "message", result)

          state
          |> put_session(session)
          |> release_in_flight(request.id)
          |> stream_fun.(request.id, request.type, request.response)

        {:error, error, %__MODULE__{} = session} ->
          error = Request.error(request.id, error)

          state
          |> put_session(session)
          |> release_in_flight(request.id)
          |> stream_fun.(error[:id], "message", error)

        {:error, error} ->
          error = Request.error(request.id, error)

          state
          |> release_in_flight(request.id)
          |> stream_fun.(error[:id], "message", error)

        _other ->
          error = Request.error(request.id, Request.internal_error())

          state
          |> release_in_flight(request.id)
          |> stream_fun.(error[:id], "message", error)
      end
    rescue
      exception ->
        :telemetry.execute(
          [:phantom, :stdio, :exception],
          %{},
          %{
            session: state.session,
            router: state.session.router,
            exception: exception,
            stacktrace: __STACKTRACE__,
            request: request
          }
        )

        IO.warn(
          "Phantom.Stdio dispatch error: #{Exception.message(exception)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        error = Request.error(request.id, Request.internal_error(Exception.message(exception)))

        state
        |> release_in_flight(request.id)
        |> stream_fun.(request.id, "message", error)
    end
  end

  defp put_session(state, %__MODULE__{} = session), do: put_in(state.session, session)

  defp request_in_flight?(state, request_id),
    do: MapSet.member?(Map.get(state, :in_flight, MapSet.new()), request_id)

  defp claim_in_flight(state, request_id),
    do:
      Map.update(
        state,
        :in_flight,
        MapSet.new([request_id]),
        &MapSet.put(&1, request_id)
      )

  defp release_in_flight(state, request_id),
    do: Map.update(state, :in_flight, MapSet.new(), &MapSet.delete(&1, request_id))

  defp partition_elicit_responses(requests, state) do
    pending = Map.get(state, :pending_elicit_ids, %{})

    Enum.reduce(requests, {[], []}, fn raw_request, {resp_acc, other_acc} ->
      if elicit_response?(raw_request, pending) do
        {[{raw_request["id"], raw_request["result"]} | resp_acc], other_acc}
      else
        {resp_acc, [raw_request | other_acc]}
      end
    end)
  end

  defp elicit_response?(%{"id" => id, "result" => result}, pending) when is_map(result),
    do: Map.has_key?(pending, id)

  defp elicit_response?(_, _), do: false

  defp route_local_elicit_response({request_id, response}, state) do
    {ref, state} = pop_in(state, [Access.key(:pending_elicit_ids, %{}), request_id])

    if ref, do: send(self(), {:phantom_elicitation_response, ref, response})

    state
  end

  defp forget_pending_elicit(state, request_id) do
    Map.update(state, :pending_elicit_ids, %{}, &Map.delete(&1, request_id))
  end

  defp cancel_inactivity(%{timer: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_inactivity(_), do: :ok

  defp set_activity(state), do: %{state | last_activity: System.system_time()}

  defp schedule_inactivity(%{timeout: :infinity} = state), do: state

  defp schedule_inactivity(state) do
    %{state | timer: Process.send_after(self(), :inactivity, state.timeout)}
  end
end

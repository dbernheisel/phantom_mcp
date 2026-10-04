defmodule Phantom.Session do
  @moduledoc """
  Represents the state of the MCP session. This is the state across the conversation
  and is the bridge between the various transports (HTTP, stdio) to persistence,
  even if stateless.
  """

  alias Phantom.Cache
  alias Phantom.Request

  @enforce_keys [:id]
  defstruct [
    :allowed_prompts,
    :allowed_resource_templates,
    :allowed_tools,
    :state,
    :id,
    :last_event_id,
    :pending_elicit,
    :pid,
    :pubsub,
    :request,
    :router,
    :stream_fun,
    :subscription_filter,
    :subscription_id,
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
    acknowledged_subscriptions: MapSet.new(),
    requests: %{},
    subscriptions: %{}
  ]

  @type t :: %__MODULE__{
          allowed_prompts: [String.t()],
          allowed_resource_templates: [String.t()],
          allowed_tools: [String.t()],
          state: term() | nil,
          assigns: map(),
          close_after_complete: boolean(),
          id: binary(),
          last_event_id: String.t() | nil,
          pending_elicit: {Phantom.Elicit.t(), term()} | nil,
          pid: pid() | nil,
          pubsub: module(),
          request: Phantom.Request.t() | nil,
          requests: map(),
          acknowledged_subscriptions: MapSet.t(),
          subscriptions: map(),
          router: module(),
          stream_fun: fun(),
          subscription_filter: map() | nil,
          subscription_id: String.t() | integer() | nil,
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
    get_in(params, ["_meta", "progressToken"])
  end

  @doc false
  def hydrate_from_request(%__MODULE__{} = session, %Request{} = request) do
    caps = Request.client_capabilities(request)

    client_capabilities =
      if is_map(caps) do
        %{
          roots: caps["roots"],
          sampling: caps["sampling"],
          elicitation: caps["elicitation"],
          ui: get_in(caps, ["extensions", "io.modelcontextprotocol/ui"]) || false
        }
      end

    session
    |> maybe_put(:client_info, Request.client_info(request))
    |> maybe_put(:client_capabilities, client_capabilities)
    |> Map.put(:request, request)
  end

  defp maybe_put(session, _key, nil), do: session
  defp maybe_put(session, key, value), do: Map.put(session, key, value)

  @doc """
  Elicit input from the client.

  Two call patterns, with protocol-aware defaults that preserve historical
  behavior:

  - **Inline blocking** (`:await` true, or default under legacy) — returns
    `{:ok, response}` where `response` is the client's JSON map (`"action"`
    and `"content"` keys), or `:not_supported` / `:timeout` / `:error`.
    Under legacy MCP protocols the call blocks via the open SSE stream.
    Under MCP `2026-07-28` the calling process waits: the request is answered
    with an `input_required` result, and the client's follow-up call, on any
    node, resumes the process and receives its eventual response.

  - **Re-entry** (`:state` set, or default under stateless) — returns the
    `session` struct with the pending elicit attached. The handler wraps
    it in the standard `{:noreply, session}` reply shape:

        {:noreply, Session.elicit(session, elicit, state: %{step: :got_input})}

    The dispatcher then converts to an `input_required` result (stateless)
    or runs through the SSE elicit round-trip + handler re-invocation
    (legacy). On resume, the handler is re-entered with `session.state`
    populated to whatever you passed as `:state`. Structure the handler
    with a function-head clause that matches on `%Session{state: %{...}}`.

  Without `:state` the call blocks inline under every protocol, so code that
  pattern-matches `{:ok, response}` works unchanged under MCP `2026-07-28`.
  The exception is a handler that runs in the request's own process, as
  resource handlers do: it cannot wait on itself, so it re-enters.

  Pick based on style preference:

      # Inline — returns the client's response.
      def my_tool(_params, session) do
        {:ok, %{"action" => "accept", "content" => %{"choice" => c}}} =
          Session.elicit(session, elicit, await: true)

        {:reply, Tool.text("got \#{c}"), session}
      end

      # Re-entry — the handler is invoked again with session.state populated
      def my_tool(%{"choice" => c}, %Session{state: %{step: :got_choice}} = session) do
        {:reply, Tool.text("got \#{c}"), session}
      end

      def my_tool(params, session) do
        {:noreply, Session.elicit(session, elicit, state: %{step: :got_choice})}
      end

  Options:
    - `:await` — `true` to force inline blocking
    - `:state` — value placed on `session.state` on re-entry; forces re-entry
      mode regardless of protocol
    - `:timeout` — max blocking time in ms (`:await` mode only; default: 5 minutes)
  """
  @spec elicit(t, Phantom.Elicit.t(), keyword()) ::
          {:ok, response :: map()}
          | t
          | :not_supported
          | :error
          | :timeout
  def elicit(session, elicitation, opts \\ []) do
    cond do
      Keyword.get(opts, :await, false) and stateless?(session) ->
        suspend_for_elicitation(session, elicitation, opts)

      Keyword.get(opts, :await, false) ->
        do_elicit(session, elicitation, opts)

      # Explicit :state — force re-entry on either protocol.
      Keyword.has_key?(opts, :state) ->
        %{session | pending_elicit: {elicitation, opts[:state]}}

      # A handler running in the request's own process cannot wait on it, so
      # it re-enters instead.
      stateless?(session) and route_pid(session) == self() ->
        %{session | pending_elicit: {elicitation, nil}}

      stateless?(session) ->
        suspend_for_elicitation(session, elicitation, opts)

      true ->
        do_elicit(session, elicitation, opts)
    end
  end

  # Under MCP 2026-07-28 nothing stays open between requests, so this process
  # waits instead: the request is answered with an `input_required` result
  # whose `requestState` names this process, and the client's follow-up call
  # (on any node) sends the response here. That call then carries the request.
  defp suspend_for_elicitation(session, elicitation, opts) do
    if elicitation_supported?(session, elicitation) do
      {pid, request_id, _progress_token} = route(session)
      ref = make_ref()

      # The request's stream shuts down its handler when it closes, and this
      # process must outlive that.
      GenServer.cast(pid, {:release_worker, request_id})

      elicitation
      |> Phantom.Tool.input_required({:__phantom_await__, self(), ref})
      |> Phantom.Router.encode_request_state(session)
      |> then(&respond(pid, request_id, &1))

      receive do
        {:phantom_resume, ^ref, response, next} ->
          continue_request(session, next)
          if is_map(response), do: {:ok, response}, else: :error
      after
        Keyword.get(opts, :timeout, @elicitation_timeout) -> :timeout
      end
    else
      :not_supported
    end
  end

  # Replies, progress, and logs for the session's request now go to the
  # follow-up call.
  defp continue_request(%__MODULE__{request: request}, {pid, request_id, _token} = next) do
    Process.put({:phantom_route, request.id}, next)

    if Process.get(:phantom_adopter) do
      Process.put(:phantom_adopter, pid)
      Process.put(:phantom_tool_request_id, request_id)
    end
  end

  defp route_pid(session), do: session |> route() |> elem(0)

  @doc false
  # Where the session's request is answered: its own transport, or the
  # follow-up call that resumed an elicitation in this process.
  def route(%__MODULE__{pid: pid, request: request} = session) do
    case request && Process.get({:phantom_route, request.id}) do
      {_pid, _request_id, _token} = next -> next
      _ -> {pid, request && request.id, request && progress_token(session)}
    end
  end

  @doc """
  Whether the session's current request is using the MCP `2026-07-28`
  stateless-core protocol.
  """
  def stateless?(%__MODULE__{request: request}),
    do: Request.modern?(request)

  def stateless?(_), do: false

  @doc """
  Whether the client declared the Tasks extension on the current request, so
  a tool may answer it with a `Phantom.Tasks`. The extension requires MCP
  `2026-07-28`, and only the current request counts.
  """
  def tasks_supported?(%__MODULE__{request: request} = session) do
    stateless?(session) and
      is_map(
        get_in(Request.client_capabilities(request) || %{}, [
          "extensions",
          Phantom.Tasks.extension()
        ])
      )
  end

  defp do_elicit(session, elicitation, opts) do
    timeout = Keyword.get(opts, :timeout, @elicitation_timeout)

    with_elicitation_support(session.client_capabilities[:elicitation], elicitation, fn ->
      # Handlers always run in a Task spawned by `Phantom.Router.run_handler/5`,
      # so the elicitation is initiated cross-process from the stream owner.
      # The session GenServer at `session.pid` owns the transport and is the
      # only process Bandit will accept writes from, so delegate there.
      if is_pid(session.pid) do
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
      else
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

  @doc false
  def elicitation_supported?(%__MODULE__{} = session, %Phantom.Elicit{} = elicitation) do
    capabilities = session.client_capabilities[:elicitation]
    is_map(capabilities) and elicitation_mode_supported?(elicitation.mode, capabilities)
  end

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
  @spec subscribe_to_resource(t(), Phantom.Router.resolved_resource() | String.t()) ::
          :ok | :error
  def subscribe_to_resource(%__MODULE__{pubsub: nil}, _resource), do: :error

  def subscribe_to_resource(session, resource),
    do: session_call(session, {:subscribe_resource, resource})

  @doc """
  Unsubscribe the session to a resource.

  This is used by the MCP Router when the client requests to subscribe to the provided resource.
  """
  @spec unsubscribe_to_resource(t(), string_uri :: String.t()) :: :ok | :error
  def unsubscribe_to_resource(%__MODULE__{pubsub: nil}, _uri), do: :error

  def unsubscribe_to_resource(session, uri),
    do: session_call(session, {:unsubscribe_resource, uri})

  @doc false
  @spec listen(t(), String.t() | integer(), map()) :: {:ok, t()} | :error
  def listen(%__MODULE__{pubsub: nil}, _subscription_id, _filter), do: :error

  def listen(%__MODULE__{} = session, subscription_id, filter)
      when (is_binary(subscription_id) or is_integer(subscription_id)) and is_map(filter) do
    with {:ok, filter} <- normalize_subscription_filter(filter) do
      Phantom.Tracker.track_session(self(), session.id, session.client_info)
      Phantom.Tracker.subscribe_session(session.pubsub, session.id)
      Phantom.Tracker.subscribe_listen(session.pubsub, principal(session), subscription_id)

      session.router
      |> Phantom.Router.resolve_resources(session, Map.get(filter, "resourceSubscriptions", []))
      |> then(&Phantom.Router.authorize_resource_subscriptions(session.router, &1, session))
      |> Enum.each(&Phantom.Tracker.subscribe_resource/1)

      task_ids =
        Phantom.Router.authorize_task_subscriptions(
          session.router,
          Map.get(filter, "taskIds", []),
          session
        )

      Enum.each(task_ids, &Phantom.Tracker.subscribe_task/1)
      filter = filter |> Map.delete("taskIds") |> maybe_put_subscription("taskIds", task_ids)

      session = %{
        session
        | close_after_complete: false,
          subscription_filter: filter,
          subscription_id: subscription_id,
          subscriptions: Map.put(session.subscriptions, subscription_id, filter)
      }

      GenServer.cast(
        session.pid,
        {:subscription_ack, subscription_id, filter}
      )

      {:ok, session}
    end
  end

  def listen(%__MODULE__{}, _subscription_id, _filter), do: :error

  def list_resource_subscriptions(session) do
    case session_call(session, :list_resource_subscriptions) do
      :error -> []
      subscriptions -> subscriptions
    end
  end

  @doc """
  Sets the log level for the SSE stream.
  Sets both for the current request for async tasks and the SSE stream
  """
  @spec set_log_level(t(), Request.t(), String.t()) :: :ok | :error
  def set_log_level(%__MODULE__{pubsub: nil, pid: pid}, _request, level) when is_pid(pid),
    do: GenServer.cast(pid, {:set_log_level, level})

  def set_log_level(%__MODULE__{} = session, _request, level),
    do: session_call(session, {:set_log_level, level})

  # Calls the session's stream process, wherever it runs. A node that has not
  # learned of the stream from `Phantom.Tracker` yet reaches it through PubSub.
  defp session_call(%__MODULE__{} = session, message) do
    case Phantom.Tracker.get_session(session) do
      nil -> Phantom.Tracker.call_session(session.pubsub, session.id, message)
      pid -> GenServer.call(pid, message)
    end
  end

  @doc "Closes the connection for the session"
  @spec finish(t() | pid) :: :ok
  def finish(%__MODULE__{pid: pid}), do: finish(pid)
  def finish(pid) when is_pid(pid), do: GenServer.cast(pid, :finish)

  @doc false
  # The cancellation arrives on its own request, so the request it names is
  # found where it runs: through the session's in-flight requests, or, for a
  # stateless `subscriptions/listen` stream, through the client's principal
  # (as `requestState` is bound to it).
  def cancel_request(%__MODULE__{} = session, request_id) do
    if stateless?(session) do
      Phantom.Tracker.cast_listen(session.pubsub, principal(session), request_id, :finish)
    else
      case Phantom.Tracker.in_flight(session.id, request_id) do
        pid when is_pid(pid) -> GenServer.cast(pid, {:cancel_request, request_id})
        nil -> :ok
      end
    end
  end

  defp principal(session), do: session.assigns[:request_state_principal]

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
  def respond(%__MODULE__{request: %{id: _}} = session, payload) do
    {pid, request_id, _token} = route(session)
    respond(pid, request_id, payload)
  end

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
  def respond_error(%__MODULE__{request: %{id: request_id}} = session, request_id, error) do
    {pid, request_id, _token} = route(session)
    respond_error(pid, request_id, error)
  end

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
  def notify(%__MODULE__{} = session, payload) do
    {pid, _request_id, _token} = route(session)
    notify(pid, payload)
  end

  def notify(pid, payload) when is_pid(pid) do
    GenServer.cast(pid, {:notify, payload})
  end

  @doc "Send a ping to the client"
  @spec ping(t | pid()) :: :ok
  def ping(%__MODULE__{pid: pid}), do: ping(pid)
  def ping(pid) when is_pid(pid), do: GenServer.cast(pid, :ping)

  @doc """
  A reference to the current request that another process, on any node, can
  pass to `notify_progress/4`. It is a JSON-safe map, so it can travel in job
  arguments, such as an Oban job's.

  Returns `nil` when the client did not ask for progress or the session has
  no PubSub, and `notify_progress/4` does nothing with `nil`.

      args = %{report_id: id, progress: Phantom.Session.progress_ref(session)}

      # In the job, on any node:
      Phantom.Session.notify_progress(args["progress"], 50, 100, "Halfway")
  """
  @spec progress_ref(t()) :: map() | nil
  def progress_ref(%__MODULE__{pubsub: pubsub, request: %Request{id: request_id}} = session)
      when is_atom(pubsub) and not is_nil(pubsub) do
    case progress_token(session) do
      nil ->
        nil

      token ->
        %{
          "pubsub" => Atom.to_string(pubsub),
          "session_id" => session.id,
          "request_id" => request_id,
          "progress_token" => token
        }
    end
  end

  def progress_ref(%__MODULE__{}), do: nil

  @doc """
  Send a progress notification to the client

  the `progress` and `total` can be a integer or float, but must be ever-increasing.
  the `total` is optional.

  Pass the session, or a reference from `progress_ref/1` to notify from
  another process or node.

  https://modelcontextprotocol.io/specification/2025-06-18/basic/utilities/progress
  """
  @spec notify_progress(t | map() | nil, number(), nil | number(), String.t() | nil) :: :ok
  def notify_progress(session, progress, total \\ nil, message \\ nil)

  def notify_progress(nil, _progress, _total, _message), do: :ok

  def notify_progress(
        %{
          "pubsub" => pubsub,
          "session_id" => session_id,
          "request_id" => request_id,
          "progress_token" => token
        },
        progress,
        total,
        message
      ) do
    pubsub
    |> String.to_existing_atom()
    |> Phantom.Tracker.cast_request(
      session_id,
      request_id,
      {:progress, token, progress, total, message}
    )
  end

  def notify_progress(%__MODULE__{} = session, progress, total, message) do
    {pid, _request_id, token} = route(session)

    cond do
      is_nil(token) and stateless?(session) -> :ok
      is_nil(token) -> ping(pid)
      true -> notify_progress(pid, token, progress, total, message)
    end
  end

  def notify_progress(pid, progress_token, progress, total),
    do: notify_progress(pid, progress_token, progress, total, nil)

  def notify_progress(pid, progress_token, progress, total, message) do
    GenServer.cast(pid, {:progress, progress_token, progress, total, message})
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

  def handle_call({:subscribe_resource, resource}, _from, state) do
    Phantom.Tracker.subscribe_resource(resource)
    {:reply, :ok, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_call({:set_log_level, log_level}, _from, state),
    do: {:reply, :ok, put_log_level(state, log_level)}

  def handle_call({:unsubscribe_resource, uri}, _from, state) do
    Phantom.Tracker.unsubscribe_resource(uri)
    {:reply, :ok, state |> set_activity() |> schedule_inactivity()}
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
    state =
      cond do
        stateless?(state.session) and map_size(state.session.subscriptions) > 0 ->
          Enum.reduce(Map.keys(state.session.subscriptions), state, fn subscription_id, acc ->
            acc.stream_fun.(
              acc,
              nil,
              "message",
              Request.subscription_cancelled(subscription_id)
            )
          end)

        stateless?(state.session) ->
          state

        true ->
          state.stream_fun.(state, nil, "closed", "finished")
      end

    {:stop, {:shutdown, :closed}, state}
  end

  @doc false
  def handle_cast({:log_legacy, level, level_name, domain, payload}, state)
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

  def handle_cast({:log_legacy, _level, _level_name, _domain, _payload}, state) do
    {:noreply, state}
  end

  def handle_cast({:log, level_name, domain, payload}, state) do
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

  def handle_cast(:ping, state) do
    cancel_inactivity(state)

    state =
      if stateless?(state.session),
        do: state.stream_fun.(state, nil, "comment", nil),
        else: state.stream_fun.(state, nil, "message", Request.ping())

    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast({:progress, token, progress, total, message}, state) do
    previous = Map.get(state, :progress, %{})[token]

    if is_number(progress) and (is_nil(previous) or progress >= previous) do
      state =
        state.stream_fun.(
          state,
          nil,
          "message",
          Request.notify_progress(token, progress, total, message)
        )

      progress_state = Map.put(Map.get(state, :progress, %{}), token, progress)

      {:noreply,
       state |> Map.put(:progress, progress_state) |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:notify, payload}, state), do: handle_cast({:send, payload}, state)

  def handle_cast({:send, payload}, state) do
    cancel_inactivity(state)
    state = state.stream_fun.(state, nil, "message", payload)
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast({:subscription_ack, subscription_id, filter}, state) do
    cancel_inactivity(state)
    payload = Request.subscriptions_acknowledged(subscription_id, filter)
    state = state.stream_fun.(state, nil, "message", payload)

    session = %{
      state.session
      | acknowledged_subscriptions:
          MapSet.put(state.session.acknowledged_subscriptions, subscription_id)
    }

    {:noreply, %{state | session: session} |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast({:respond, request_id, payload}, state) do
    cancel_inactivity(state)
    request = state.session.requests[request_id]
    payload = normalize_response_payload(payload, request, state.session)
    state = state.stream_fun.(state, request_id, "message", payload)
    requests = Map.delete(state.session.requests, request_id)
    state = put_in(state.session.requests, requests)
    Phantom.Tracker.untrack_in_flight(state.session.id, request_id)
    state = release_in_flight(state, request_id)
    maybe_finish(state)
  end

  def handle_cast({:release_worker, request_id}, state) do
    case Map.pop(Map.get(state, :workers, %{}), request_id) do
      {nil, _workers} ->
        {:noreply, state}

      {{_pid, monitor_ref}, workers} ->
        Process.demonitor(monitor_ref, [:flush])
        {:noreply, Map.put(state, :workers, workers)}
    end
  end

  def handle_cast({:cancel_request, request_id}, state) do
    {worker, workers} = Map.pop(Map.get(state, :workers, %{}), request_id)

    with {pid, monitor_ref} <- worker do
      Process.demonitor(monitor_ref, [:flush])
      Process.exit(pid, :shutdown)
    end

    requests = Map.delete(state.session.requests, request_id)
    state = %{state | session: %{state.session | requests: requests}}
    maybe_finish(Map.put(state, :workers, workers))
  end

  def handle_cast({:subscribe_resource, resource}, state) do
    cancel_inactivity(state)
    Phantom.Tracker.subscribe_resource(resource)
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast({:unsubscribe_resource, uri}, state) do
    cancel_inactivity(state)
    Phantom.Tracker.unsubscribe_resource(uri)
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast({:resources_updated, updates}, state) do
    templates_by_name =
      state.session
      |> Cache.list(state.session.router, :resource_templates)
      |> Map.new(&{&1.name, &1})

    {resolved, uris} =
      Enum.reduce(updates, {[], []}, fn
        {uri, params, %Phantom.ResourceTemplate{} = template}, {resources, uris}
        when is_binary(uri) and is_map(params) ->
          {[{uri, params, template} | resources], uris}

        {uri, params, template_name}, {resources, uris}
        when is_binary(uri) and is_map(params) and is_binary(template_name) ->
          case Map.fetch(templates_by_name, template_name) do
            {:ok, template} -> {[{uri, params, template} | resources], uris}
            :error -> {resources, uris}
          end

        uri, {resources, uris} when is_binary(uri) ->
          {resources, [uri | uris]}

        _invalid, acc ->
          acc
      end)

    resolved =
      resolved
      |> Enum.reverse()
      |> Phantom.Router.available_resolved_resources(state.session.router, state.session)

    resources =
      (resolved ++
         Phantom.Router.resolve_resources(state.session.router, state.session, Enum.reverse(uris)))
      |> Enum.uniq_by(&elem(&1, 0))

    authorized =
      Phantom.Router.authorize_resource_subscriptions(
        state.session.router,
        resources,
        state.session
      )

    notifications =
      Enum.flat_map(authorized, fn {uri, _params, _template} ->
        subscription_notifications(
          state.session,
          "resourceSubscriptions",
          uri,
          Request.resource_updated(%{uri: uri})
        )
      end)

    if notifications != [] do
      cancel_inactivity(state)
      state = stream_notifications(state, notifications)
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:task_updated, task_id}, state) do
    notifications =
      case Phantom.Router.get_task_for_notification(state.session.router, task_id, state.session) do
        {:ok, task} ->
          if task.status in [:completed, :failed, :cancelled],
            do: Phantom.Tracker.unsubscribe_task(task.id)

          subscription_notifications(
            state.session,
            "taskIds",
            task.id,
            Request.task_updated(Phantom.Tasks.to_json(task))
          )

        :error ->
          []
      end

    if notifications != [] do
      cancel_inactivity(state)
      state = stream_notifications(state, notifications)
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:resource_updated, uri}, state),
    do: handle_cast({:resources_updated, [uri]}, state)

  def handle_cast(:tools_updated, state) do
    notifications =
      if state.session.allowed_tools == nil,
        do:
          subscription_notifications(state.session, "toolsListChanged", Request.tools_updated()),
        else: []

    if notifications != [] do
      cancel_inactivity(state)
      state = stream_notifications(state, notifications)
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:prompts_updated, state) do
    notifications =
      if state.session.allowed_prompts == nil,
        do:
          subscription_notifications(
            state.session,
            "promptsListChanged",
            Request.prompts_updated()
          ),
        else: []

    if notifications != [] do
      cancel_inactivity(state)
      state = stream_notifications(state, notifications)
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:resources_updated, state) do
    notifications =
      if state.session.allowed_resource_templates == nil,
        do:
          subscription_notifications(
            state.session,
            "resourcesListChanged",
            Request.resources_updated()
          ),
        else: []

    if notifications != [] do
      cancel_inactivity(state)
      state = stream_notifications(state, notifications)
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:set_log_level, log_level}, state),
    do: {:noreply, put_log_level(state, log_level)}

  defp put_log_level(state, log_level) do
    level = Keyword.fetch!(Phantom.ClientLogger.log_levels(), String.to_existing_atom(log_level))
    %{state | log_level: level}
  end

  defp normalize_response_payload(%{result: result} = payload, %Request{} = request, session)
       when is_map(result) do
    %{payload | result: Request.normalize_result(result, request, session)}
  end

  defp normalize_response_payload(payload, _request, _session), do: payload

  defp normalize_subscription_filter(filter) do
    resource_subscriptions = Map.get(filter, "resourceSubscriptions", [])
    task_ids = Map.get(filter, "taskIds", [])

    if string_list?(resource_subscriptions) and string_list?(task_ids) do
      normalized =
        %{}
        |> maybe_put_subscription("toolsListChanged", filter["toolsListChanged"] == true)
        |> maybe_put_subscription("promptsListChanged", filter["promptsListChanged"] == true)
        |> maybe_put_subscription("resourcesListChanged", filter["resourcesListChanged"] == true)
        |> maybe_put_subscription("resourceSubscriptions", Enum.uniq(resource_subscriptions))
        |> maybe_put_subscription("taskIds", Enum.uniq(task_ids))

      {:ok, normalized}
    else
      :error
    end
  end

  defp string_list?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

  defp maybe_put_subscription(filter, _key, false), do: filter
  defp maybe_put_subscription(filter, _key, []), do: filter
  defp maybe_put_subscription(filter, key, value), do: Map.put(filter, key, value)

  defp subscription_requested?(%__MODULE__{subscription_filter: nil}, _key), do: true

  defp subscription_requested?(%__MODULE__{subscription_filter: filter}, key),
    do: filter[key] == true

  defp subscription_requested?(%__MODULE__{subscription_filter: nil}, _key, _value), do: true

  defp subscription_requested?(%__MODULE__{subscription_filter: filter}, key, value),
    do: value in Map.get(filter, key, [])

  defp subscription_notifications(
         %__MODULE__{subscriptions: subscriptions} = session,
         key,
         notification
       )
       when map_size(subscriptions) > 0 do
    for {id, filter} <- subscriptions,
        MapSet.member?(session.acknowledged_subscriptions, id),
        filter[key] == true do
      add_subscription_id(notification, id)
    end
  end

  defp subscription_notifications(session, key, notification) do
    if subscription_requested?(session, key),
      do: [add_subscription_id(notification, session)],
      else: []
  end

  defp subscription_notifications(
         %__MODULE__{subscriptions: subscriptions} = session,
         key,
         value,
         notification
       )
       when map_size(subscriptions) > 0 do
    for {id, filter} <- subscriptions,
        MapSet.member?(session.acknowledged_subscriptions, id),
        value in Map.get(filter, key, []) do
      add_subscription_id(notification, id)
    end
  end

  defp subscription_notifications(session, key, value, notification) do
    if subscription_requested?(session, key, value),
      do: [add_subscription_id(notification, session)],
      else: []
  end

  defp stream_notifications(state, notifications) do
    Enum.reduce(notifications, state, fn notification, acc ->
      acc.stream_fun.(acc, nil, "message", notification)
    end)
  end

  defp add_subscription_id(notification, %__MODULE__{subscription_id: nil}), do: notification

  defp add_subscription_id(notification, %__MODULE__{subscription_id: subscription_id}) do
    add_subscription_id(notification, subscription_id)
  end

  defp add_subscription_id(notification, subscription_id) do
    params = Map.get(notification, :params, %{})
    meta = Map.get(params, :_meta, %{})
    meta = Map.put(meta, "io.modelcontextprotocol/subscriptionId", subscription_id)
    Map.put(notification, :params, Map.put(params, :_meta, meta))
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

  def handle_info({:phantom_worker_started, request_id, pid}, state) do
    monitor_ref = Process.monitor(pid)
    workers = Map.put(Map.get(state, :workers, %{}), request_id, {pid, monitor_ref})
    {:noreply, Map.put(state, :workers, workers)}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    workers =
      state
      |> Map.get(:workers, %{})
      |> Enum.reject(fn {_id, {_pid, ref}} -> ref == monitor_ref end)
      |> Map.new()

    {:noreply, Map.put(state, :workers, workers)}
  end

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

  def handle_info(:inactivity, state) do
    cond do
      not state.session.close_after_complete ->
        state =
          if stateless?(state.session),
            do: state.stream_fun.(state, nil, "comment", nil),
            else: state.stream_fun.(state, nil, "message", Request.ping())

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
            case validate_stdio_request(request) do
              :ok ->
                state_acc = hydrate_stdio_request(state_acc, request)
                dispatch_stdio_request(request, state_acc)

              {:error, error} ->
                payload = Request.error(request.id, error)
                state_acc.stream_fun.(state_acc, request.id, "message", payload)
            end

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

  def handle_info({:phantom_dispatch_error, :batch_not_supported}, state) do
    cancel_inactivity(state)
    error = Request.error(nil, Request.invalid("Batch requests are not supported"))
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

  @doc false
  def terminate(_reason, state) do
    Enum.each(Map.get(state, :workers, %{}), fn {_id, {pid, monitor_ref}} ->
      Process.demonitor(monitor_ref, [:flush])
      Process.exit(pid, :shutdown)
    end)

    # The HTTP transport runs this loop in its own process and returns the
    # conn as it was last sent.
    if conn = Map.get(state, :conn), do: send(self(), {:phantom_final_conn, conn})

    :ok
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
      Phantom.Tracker.subscribe_request(state.session.pubsub, state.session.id, request_id)

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
          requests = Map.put(session.requests, request.id, request)
          put_in(state.session, %{session | requests: requests})

        {:reply, nil, %__MODULE__{} = session} ->
          state
          |> put_session(session)
          |> release_in_flight(request.id)

        {:reply, result, %__MODULE__{} = session} ->
          result = Request.normalize_result(result, request, session)
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

  defp validate_stdio_request(%Request{} = request) do
    if Request.stateless_envelope?(request),
      do: Request.validate(request),
      else: :ok
  end

  defp hydrate_stdio_request(state, request) do
    state = put_in(state.session, hydrate_from_request(state.session, request))

    if Request.modern?(request) do
      level =
        Enum.find_value(Phantom.ClientLogger.log_levels(), 0, fn {name, grade} ->
          if Atom.to_string(name) == Request.log_level(request), do: grade
        end)

      Map.put(state, :log_level, level)
    else
      state
    end
  end

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

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
      elicitation: false
    },
    close_after_complete: true,
    requests: %{}
  ]

  @type t :: %__MODULE__{
          allowed_prompts: [String.t()],
          allowed_resource_templates: [String.t()],
          allowed_tools: [String.t()],
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
            roots: false | map()
          },
          transport_pid: pid()
        }

  @elicitation_timeout :timer.minutes(5)

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

  Blocks until the client responds or timeout is reached. Returns
  `{:ok, response}` where response is the client's JSON response map
  (with `"action"` and `"content"` keys).

  Options:
    - `:timeout` - max time to wait in ms (default: 5 minutes)
  """
  @spec elicit(t, Phantom.Elicit.t(), keyword()) ::
          {:ok, response :: map()}
          | :not_supported
          | :error
          | :timeout
  def elicit(session, elicitation, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @elicitation_timeout)
    meta = Phantom.Tracker.get_session_meta(session.id)

    capabilities =
      case meta do
        %{client_capabilities: %{elicitation: caps}} -> caps
        _ -> nil
      end

    with_elicitation_support(capabilities, elicitation, fn ->
      case {Phantom.Tracker.get_session(session), meta} do
        {nil, %{stdio_output: output}} -> stdio_elicit(output, elicitation, timeout)
        {nil, _} -> :error
        {pid, _} when is_pid(pid) ->
          try do
            GenServer.call(pid, {:elicit, elicitation}, timeout)
          catch
            :exit, {:timeout, _} -> :timeout
          end
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

  defp stdio_elicit(output, elicitation, timeout) do
    {:ok, request} =
      Request.build(%{
        "id" => UUIDv7.generate(),
        "jsonrpc" => "2.0",
        "method" => "elicitation/create",
        "params" => Phantom.Elicit.to_json(elicitation)
      })

    IO.write(output, JSON.encode!(Request.to_json(request)) <> "\n")
    stdio_await_response(request.id, timeout)
  end

  defp stdio_await_response(request_id, timeout) do
    receive do
      {:phantom_dispatch, requests} ->
        case pop_response(requests, request_id) do
          {nil, _requests} ->
            send(self(), {:phantom_dispatch, requests})
            stdio_await_response(request_id, timeout)

          {response, []} ->
            {:ok, response}

          {response, remaining} ->
            send(self(), {:phantom_dispatch, remaining})
            {:ok, response}
        end
    after
      timeout -> :timeout
    end
  end

  defp pop_response(requests, request_id) do
    Enum.reduce(requests, {nil, []}, fn
      %{"id" => ^request_id, "result" => result}, {nil, rest} when is_map(result) ->
        {result, rest}

      other, {found, rest} ->
        {found, [other | rest]}
    end)
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
  @spec set_log_level(Session.t(), Request.t(), String.t()) :: :ok
  def set_log_level(%__MODULE__{} = session, request, level) do
    case Phantom.Tracker.get_session(session) || session.pid do
      nil -> :error
      pid -> GenServer.cast(pid, {:set_log_level, request, level})
    end
  end

  @doc "Closes the connection for the session"
  @spec finish(Session.t() | pid) :: :ok
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

  def handle_call({:elicit, elicitation}, from, state) do
    cancel_inactivity(state)

    {:ok, request} =
      Request.build(%{
        "id" => UUIDv7.generate(),
        "jsonrpc" => "2.0",
        "method" => "elicitation/create",
        "params" => Phantom.Elicit.to_json(elicitation)
      })

    if elicitation.mode == :url do
      Phantom.Tracker.track_request(self(), elicitation.elicitation_id, %{type: :elicitation})
    end

    state =
      state
      |> Map.update(:elicitation_callers, %{request.id => from}, &Map.put(&1, request.id, from))
      |> state.stream_fun.(request.id, "message", Request.to_json(request))

    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  @doc false
  def handle_cast({:elicitation_response, request_id, response}, state) do
    case pop_in(state, [:elicitation_callers, request_id]) do
      {nil, state} ->
        {:noreply, state}

      {from, state} ->
        GenServer.reply(from, {:ok, response})
        {:noreply, state}
    end
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

    state =
      Enum.reduce(requests, state, fn raw_request, state_acc ->
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

  defp dispatch_stdio_request(%Request{id: nil} = request, state) do
    # Notifications have no id; dispatch but don't write a response
    try do
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
  end

  defp dispatch_stdio_request(request, state) do
    stream_fun = state.stream_fun

    try do
      case state.session.router.dispatch_method([
             request.method,
             request.params,
             request,
             state.session
           ]) do
        {:noreply, %__MODULE__{} = session} ->
          requests = Map.put(session.requests, request.id, request.response)
          put_in(state.session, %{session | requests: requests})

        {:reply, result, %__MODULE__{} = session} ->
          request = Request.result(request, "message", result)
          state = put_in(state.session, session)
          stream_fun.(state, request.id, request.type, request.response)

        {:reply, nil, %__MODULE__{} = session} ->
          put_in(state.session, session)

        {:error, error, %__MODULE__{} = session} ->
          error = Request.error(request.id, error)
          state = put_in(state.session, session)
          stream_fun.(state, error[:id], "message", error)

        {:error, error} ->
          error = Request.error(request.id, error)
          stream_fun.(state, error[:id], "message", error)

        _other ->
          error = Request.error(request.id, Request.internal_error())
          stream_fun.(state, error[:id], "message", error)
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
        stream_fun.(state, request.id, "message", error)
    end
  end

  defp cancel_inactivity(%{timer: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_inactivity(_), do: :ok

  defp set_activity(state), do: %{state | last_activity: System.system_time()}

  defp schedule_inactivity(%{timeout: :infinity} = state), do: state

  defp schedule_inactivity(state) do
    %{state | timer: Process.send_after(self(), :inactivity, state.timeout)}
  end
end

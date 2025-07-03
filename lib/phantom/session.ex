defmodule Phantom.Session do
  @moduledoc """
  Represents the state of the MCP session. This is the state across the conversation
  and is the bridge between the various transports (HTTP, stdio) to persistence,
  even if stateless.
  """

  require Logger

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

  @doc "Elicit input from the client"
  @spec elicit(t, Phantom.Elicit.t()) ::
          {:ok, request_id :: String.t()}
          | :not_supported
  def elicit(session, elicitation) do
    if session.client_capabilities.elicitation do
      case Phantom.Tracker.get_session(session) do
        nil -> :error
        pid -> GenServer.call(pid, {:elicit, elicitation})
      end
    else
      :not_supported
    end
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
    case Phantom.Tracker.get_session(session) do
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
    timer = Process.send_after(self(), :inactivity, state.timeout)
    state = Map.put(state, :timer, timer)

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

  def handle_call({:elicit, elicitation}, _from, state) do
    cancel_inactivity(state)

    {:ok, request} =
      Request.build(%{
        "id" => UUIDv7.generate(),
        "jsonrpc" => "2.0",
        "method" => "elicitation/create",
        "params" => Phantom.Elicit.to_json(elicitation)
      })

    state = state.stream_fun.(state, request.id, "message", Request.to_json(request))
    {:reply, {:ok, request.id}, state |> set_activity() |> schedule_inactivity()}
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
    state.stream_fun.(state, nil, "message", Request.resource_updated(%{uri: uri}))
    {:noreply, state |> set_activity() |> schedule_inactivity()}
  end

  def handle_cast(:tools_updated, state) do
    notify? = state.session.allowed_tools == nil

    if notify? do
      cancel_inactivity(state)
      state.stream_fun.(state, nil, "message", Request.tools_updated())
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:prompts_updated, state) do
    notify? = state.session.allowed_prompts == nil

    if notify? do
      cancel_inactivity(state)
      state.stream_fun.(state, nil, "message", Request.prompts_updated())
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:resources_updated, state) do
    notify? = state.session.allowed_resource_templates == nil

    if notify? do
      cancel_inactivity(state)
      state.stream_fun.(state, nil, "message", Request.resources_updated())
      {:noreply, state |> set_activity() |> schedule_inactivity()}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:set_log_level, request, log_level}, state) do
    state = state.stream_fun.(state, request.id, "message", %{})
    {:noreply, %{state | log_level: log_level}}
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

  def handle_info(_what, state) do
    {:noreply, state}
  end

  defp cancel_inactivity(%{timer: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_inactivity(_), do: :ok

  defp set_activity(state), do: %{state | last_activity: System.system_time()}

  defp schedule_inactivity(state) do
    %{state | timer: Process.send_after(self(), :inactivity, state.timeout)}
  end
end

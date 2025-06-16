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
    :id,
    :last_event_id,
    :pid,
    :prompts,
    :pubsub,
    :resource_templates,
    :router,
    :stream_fun,
    :tools,
    :tracker,
    assigns: %{},
    close_after_complete: true,
    subscribed: [],
    requests: %{}
  ]

  @type t :: %__MODULE__{
          assigns: map(),
          last_event_id: String.t() | nil,
          close_after_complete: boolean(),
          id: binary(),
          pid: pid() | nil,
          prompts: [atom()],
          pubsub: module(),
          requests: map(),
          resource_templates: [atom()],
          router: module(),
          stream_fun: fun(),
          subscribed: map(),
          tools: [atom()]
        }

  @spec new(String.t() | nil, Keyword.t() | map) :: t()
  def new(session_id, opts \\ []) do
    struct!(__MODULE__, [id: session_id || UUIDv7.generate()] ++ opts)
  end

  def list do
    Phoenix.Tracker.list(Phantom.Tracker, "sessions")
  end

  def get(id) do
    case Phoenix.Tracker.get_by_key(Phantom.Tracker, "sessions", id) do
      [{pid, _} | _] -> pid
      _ -> nil
    end
  end

  @spec assign(t(), atom(), any()) :: t()
  def assign(session, key, value) do
    %{session | assigns: Map.put(session.assigns, key, value)}
  end

  @spec assign(t(), map()) :: t()
  def assign(session, map) do
    %{session | assigns: Map.merge(session.assigns, Map.new(map))}
  end

  def subscribe_to_resource(%__MODULE__{pubsub: nil}, _uri), do: :error

  def subscribe_to_resource(session, uri) do
    case get(session.id) do
      nil -> :error
      pid -> GenServer.cast(pid, {:resource_subscribe, uri})
    end
  end

  def set_log_level(%__MODULE__{pubsub: nil}, _request, _level), do: :error

  def set_log_level(%__MODULE__{id: id}, request, level) do
    case get(id) do
      nil -> :error
      pid -> GenServer.cast(pid, {:set_log_level, request, level})
    end
  end

  def finish(%__MODULE__{pid: pid}), do: finish(pid)
  def finish(pid) when is_pid(pid), do: GenServer.cast(pid, :finish)

  def tool_respond(session, request_id, payload) do
    respond(session, request_id, %{content: List.wrap(payload)})
  end

  def resource_respond(session, request_id, payload) do
    respond(session, request_id, %{content: List.wrap(payload)})
  end

  @doc """
  Send a response for the request for the given session
  """
  def respond(%__MODULE__{pid: pid}, request_id, payload), do: respond(pid, request_id, payload)

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

  @log_grades [
    emergency: 1,
    alert: 2,
    critical: 3,
    error: 4,
    warning: 5,
    notice: 6,
    info: 7,
    debug: 8
  ]

  @doc false
  defp do_log(%__MODULE__{pubsub: nil}, _level_num, _name, _domain, _payload), do: :ok

  defp do_log(%__MODULE__{id: id}, level_num, level_name, domain, payload) do
    case Phoenix.Tracker.get_by_key(Phantom.Tracker, "sessions", id) do
      [{pid, _} | _] ->
        dbg()
        GenServer.cast(pid, {:log, level_num, level_name, domain, payload})

      _ ->
        :ok
    end
  end

  for {name, level} <- @log_grades do
    def log(session, unquote(name), domain, payload) do
      do_log(session, unquote(level), unquote(name), domain, payload)
    end

    @doc "Notify the client with a log at level \"#{name}\""
    def unquote(:"log_#{name}")(session, domain, payload) do
      do_log(session, unquote(level), unquote(name), domain, payload)
    end

    def handle_cast({:set_log_level, request, unquote(to_string(name))}, state) do
      state = state.stream_fun.(state, request.id, "message", %{})
      {:noreply, %{state | log_level: unquote(level)}}
    end
  end

  @doc false
  def start_loop(opts) do
    session = Keyword.fetch!(opts, :session)
    timeout = Keyword.fetch!(opts, :timeout)
    {cb, opts} = Keyword.pop(opts, :continue_fun)
    timer = Process.send_after(self(), :inactivity, timeout)

    Process.set_label({Phantom.Session, session.id})

    :gen_server.enter_loop(
      __MODULE__,
      [],
      Map.new(
        opts ++
          [log_level: nil, timeout: timeout, last_activity: System.system_time(), timer: timer]
      ),
      self(),
      {:continue, cb}
    )
  end

  @doc false
  def handle_continue(cb, state) when is_function(cb, 1) do
    maybe_finish(cb.(state))
  end

  @doc false
  def handle_cast(:finish, state) do
    state = state.stream_fun.(state, nil, "closed", "finished")
    {:stop, {:shutdown, :closed}, state}
  end

  @doc false
  def handle_cast({:log, level, level_name, domain, payload}, state)
      when state.log_level and level <= state.log_level do
    {:noreply,
     state.stream_fun.(
       state,
       nil,
       "message",
       Request.notify(%{level: level_name, logger: domain, data: payload})
     )}
  end

  def handle_cast({:log, _level, _domain, _payload}, state) do
    {:noreply, state}
  end

  def handle_cast({:respond, request_id, payload}, state) do
    cancel_inactivity(state)
    state = state.stream_fun.(state, request_id, "message", payload)
    requests = Map.delete(state.session.requests, request_id)
    state = put_in(state.session.requests, requests)
    maybe_finish(state)
  end

  def handle_cast({:resource, uri}, state) do
    if uri not in state.subscribed do
      Phoenix.PubSub.subscribe(state.session.pubsub, "phantom:resources")
      {:noreply, put_in(state.subscribed, [uri | state.subscribed])}
    else
      {:noreply, state}
    end
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
    if System.system_time() - state.last_activity > state.timeout do
      state = state.stream_fun.(state, nil, "closed", "inactivity")
      {:stop, {:shutdown, :closed}, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:resource_subscribe, uri}, state) do
    if uri in state.subscribed do
      {:noreply, state.stream_fun.(state, nil, "message", Phantom.ResourceTemplate.updated(uri))}
    else
      {:noreply, state}
    end
  end

  def handle_info(what, state) do
    Logger.warning(inspect(what))
    {:noreply, state}
  end

  # Phoenix.PubSub.broadcast(Test.PubSub, "phantom:resource", "anything")

  defp cancel_inactivity(%{timer: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_inactivity(_), do: :ok

  defp set_activity(state), do: %{state | last_activity: System.system_time()}

  defp schedule_inactivity(state) do
    %{state | timer: Process.send_after(self(), :inactivity, state.timeout)}
  end
end

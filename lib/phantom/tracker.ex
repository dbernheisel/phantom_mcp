defmodule Phantom.Tracker do
  @moduledoc """
  Track open streams so that notifications and requests can be sent to clients.

  For example, a request may need to elicit more input from the client, so the
  first request stream will remain open, and the notification stream will send
  and new request to the client, and the client will POST its response. The
  new response connection will notify the first request connection with the result
  and the tool can continue with the elicited information.

  See `m:Phantom#module-persistent-streams` section for more information.
  """

  use Phoenix.Tracker

  @sessions "phantom:sessions"
  @requests "phantom:requests"
  @resources "phantom:resources"

  @available Code.ensure_loaded?(Phoenix.Tracker) and Code.ensure_loaded?(Phoenix.PubSub)

  def resource_subscription_topic, do: @resources
  def requests_topic, do: @requests
  def sessions_topic, do: @sessions

  @doc false
  if @available do
    def start_link(opts) do
      opts = Keyword.merge([name: __MODULE__], opts)
      Phoenix.Tracker.start_link(__MODULE__, opts, opts)
    end
  else
    def start_link(_opts), do: :error
  end

  @doc false
  if @available do
    def init(opts) do
      server = Keyword.fetch!(opts, :pubsub_server)
      {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
    end
  else
    def init(_opts), do: :ignore
  end

  @doc "Track a request PID"
  if @available do
    def track_request(pid, request_id, meta \\ %{}) do
      Phoenix.Tracker.track(__MODULE__, pid, @requests, request_id, meta)
    end
  else
    def track_request(_pid, _request_id, _meta \\ %{}), do: {:error, :not_available}
  end

  @doc "Track a session PID"
  if @available do
    def track_session(pid, session_id, meta \\ %{}) do
      Phoenix.Tracker.track(__MODULE__, pid, @sessions, session_id, meta)
    end
  else
    def track_session(pid, session_id, meta \\ %{}), do: {:error, :not_available}
  end

  @doc "Return a list of all open sessions"
  if @available do
    def list_sessions, do: Phoenix.Tracker.list(__MODULE__, @sessions)
  else
    def list_sessions, do: []
  end

  @doc "Return a list of all open requests"
  if @available do
    def list_requests, do: Phoenix.Tracker.list(__MODULE__, @requests)
  else
    def list_requests, do: []
  end

  @doc "Return a list of all listening for resources"
  if @available do
    def list_resource_listeners, do: Phoenix.Tracker.list(__MODULE__, @resources)
  else
    def list_resource_listeners, do: []
  end

  @doc "Fetch the PID of the open request by ID"
  def get_request(%Phantom.Request{id: request_id}), do: get_request(request_id)

  if @available do
    def get_request(request_id) do
      case Phoenix.Tracker.get_by_key(__MODULE__, @requests, request_id) do
        [{pid, _} | _] ->
          if Process.alive?(pid) do
            pid
          else
            Phoenix.Tracker.untrack(__MODULE__, pid)
            nil
          end

        _ ->
          nil
      end
    end
  else
    def get_request(_request_id), do: nil
  end

  @doc "Fetch the PID of the open session by ID"
  def get_session(%Phantom.Session{id: session_id}), do: get_session(session_id)

  if @available do
    def get_session(session_id) do
      case Phoenix.Tracker.get_by_key(__MODULE__, @sessions, session_id) do
        [{pid, _} | _] ->
          if Process.alive?(pid) do
            pid
          else
            Phoenix.Tracker.untrack(__MODULE__, pid)
            nil
          end

        _ ->
          nil
      end
    end
  else
    def get_session(_session_id), do: nil
  end

  @doc "Untrack the processe for everything"
  if @available do
    def untrack(pid), do: Phoenix.Tracker.untrack(__MODULE__, pid)
  else
    def untrack(_pid), do: :ok
  end

  @doc "Untrack any processes for the session"
  def untrack_session(%Phantom.Session{id: session_id}), do: untrack_session(session_id)

  if @available do
    def untrack_session(session_id) do
      __MODULE__
      |> Phoenix.Tracker.get_by_key(@sessions, session_id)
      |> Enum.each(fn {pid, _} -> Phoenix.Tracker.untrack(__MODULE__, pid) end)

      :ok
    end
  else
    def untrack_session(_session_id), do: :ok
  end

  @doc "Untrack any processes for the request"
  def untrack_request(%Phantom.Request{id: request_id}), do: untrack_request(request_id)

  if @available do
    def untrack_request(request_id) do
      __MODULE__
      |> Phoenix.Tracker.get_by_key(@requests, request_id)
      |> Enum.each(fn {pid, _meta} -> Phoenix.Tracker.untrack(__MODULE__, pid) end)

      :ok
    end
  else
    def untrack_request(_request_id), do: :ok
  end

  @doc "Subscribe the process to resource notifications from the PubSub on topic #{inspect(@resources)}"
  if @available do
    def subscribe_resource(uri) do
      Phoenix.Tracker.track(__MODULE__, self(), @resources, uri, %{})
    end
  else
    def subscribe_resource(pubsub, uri), do: {:error, :not_available}
  end

  @doc "Unsubscribe the process to resource notifications from the PubSub on topic #{inspect(@resources)}"
  if @available do
    def unsubscribe_resource(uri) do
      Phoenix.Tracker.untrack(__MODULE__, self(), @resources, uri)
    end
  else
    def unsubscribe_resource(pubsub, uri), do: {:error, :not_available}
  end

  @doc "Notify any listening MCP sessions that the resource has updated"
  if @available do
    def notify_resource_updated(uri) do
      {:ok,
       __MODULE__
       |> Phoenix.Tracker.get_by_key(@resources, uri)
       |> Enum.count(fn {pid, _meta} -> GenServer.cast(pid, {:resource_updated, uri}) end)}
    end
  else
    def notify_resource_updated(_), do: {:ok, 0}
  end

  @doc "Notify any listening MCP sessions that the list of tools has updated"
  if @available do
    def notify_tool_list do
      {:ok,
       Enum.count(list_sessions(), fn {session_id, _} ->
         if pid = get_session(session_id), do: GenServer.cast(pid, :tools_updated)
       end)}
    end
  else
    def notify_tool_list(_), do: {:ok, 0}
  end

  @doc "Notify any listening MCP sessions that the list of prompts has updated"
  if @available do
    def notify_prompt_list do
      {:ok,
       Enum.count(list_sessions(), fn {session_id, _} ->
         if pid = get_session(session_id), do: GenServer.cast(pid, :prompts_updated)
       end)}
    end
  else
    def notify_prompt_list(_), do: {:ok, 0}
  end

  @doc "Notify any listening MCP sessions that the list of prompts has updated"
  if @available do
    def notify_resource_list do
      {:ok,
       Enum.count(list_sessions(), fn {session_id, _} ->
         if pid = get_session(session_id), do: GenServer.cast(pid, :resources_updated)
       end)}
    end
  else
    def notify_resource_list(_), do: {:ok, 0}
  end

  @doc false
  if @available do
    def handle_diff(diff, state) do
      for {topic, {joins, leaves}} <- diff do
        for {key, meta} <- joins do
          msg = {:join, key, meta}
          Phoenix.PubSub.direct_broadcast!(state.node_name, state.pubsub_server, topic, msg)
        end

        for {key, meta} <- leaves do
          msg = {:leave, key, meta}
          Phoenix.PubSub.direct_broadcast!(state.node_name, state.pubsub_server, topic, msg)
        end
      end

      {:ok, state}
    end
  else
    def handle_diff(_diff, state), do: {:ok, state}
  end
end

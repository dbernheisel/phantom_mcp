if Code.ensure_loaded?(Phoenix.Tracker) and Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Phantom.Tracker do
    @moduledoc """
    Track SSE streams so that notifications and messages can be sent to Streamable HTTP
    clients

    See `m:Phantom#module-persistent-streams` section for more information.
    """

    use Phoenix.Tracker
    @sessions "phantom:sessions"
    @requests "phantom:requests"

    def start_link(opts) do
      opts = Keyword.merge([name: __MODULE__], opts)
      Phoenix.Tracker.start_link(__MODULE__, opts, opts)
    end

    @doc false
    def init(opts) do
      server = Keyword.fetch!(opts, :pubsub_server)
      {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
    end

    @doc false
    def track(pid, topic, key, meta) do
      Phoenix.Tracker.track(__MODULE__, pid, topic, key, meta)
    end

    @doc false
    def list_sessions do
      Phoenix.Tracker.list(__MODULE__, @sessions)
    end

    @doc false
    def list_requests do
      Phoenix.Tracker.list(__MODULE__, @requests)
    end

    @doc false
    def get_by_key(topic, key) do
      case Phoenix.Tracker.get_by_key(__MODULE__, topic, key) do
        [{pid, _} | _] -> pid
        _ -> nil
      end
    end

    @doc false
    def untrack_session(session_id) do
      case get_by_key(@sessions, session_id) do
        nil -> :ok
        pid -> Phoenix.Tracker.untrack(__MODULE__, pid)
      end
    end

    def untrack_request(request_id) do
      case get_by_key(@requests, request_id) do
        nil -> :ok
        pid -> Phoenix.Tracker.untrack(__MODULE__, pid)
      end
    end

    @doc false
    def untrack(pid) when is_pid(pid) do
      Phoenix.Tracker.untrack(__MODULE__, pid)
    end

    @doc false
    def untrack(pid, topic, key) when is_pid(pid) do
      Phoenix.Tracker.untrack(__MODULE__, pid, topic, key)
    end

    @doc false
    def pid_for_session(%{id: id}), do: pid_for_session(id)

    def pid_for_session(session_id) do
      case Phoenix.Tracker.get_by_key(__MODULE__, @sessions, session_id) do
        [{pid, _} | _] ->
          if Process.alive?(pid) do
            pid
          else
            untrack(pid)
            nil
          end

        [] ->
          nil
      end
    end

    @doc false
    def pid_for_request(%{id: id}), do: pid_for_request(id)

    def pid_for_request(request_id) do
      case Phoenix.Tracker.get_by_key(__MODULE__, @requests, request_id) do
        [{pid, _} | _] ->
          if Process.alive?(pid) do
            pid
          else
            untrack(pid)
            nil
          end

        [] ->
          nil
      end
    end

    @doc false
    def resource_subscribe(pubsub, topic) do
      Phoenix.PubSub.subscribe(pubsub, topic)
    end

    @doc false
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
  end
else
  defmodule Phantom.Tracker do
    @doc false
    def track(_pid, _topic, _key, _meta), do: :error
    @doc false
    def untrack(_pid), do: :ok
    @doc false
    def untrack(_pid, _topic, _key), do: :ok
    @doc false
    def get_by_key(_topic, _key), do: nil
    @doc false
    def list_sessions(), do: []
    @doc false
    def list_requests(), do: []
    @doc false
    def resource_subscribe(_pubsub, _topic), do: :error
    @doc false
    def get_by_key(_topic, _key), do: nil
    @doc false
    def untrack_session(_session_id), do: :ok
    @doc false
    def untrack_request(_request_id), do: :ok
    @doc false
    def pid_for_session(_), do: nil
    @doc false
    def pid_for_request(_), do: nil
  end
end

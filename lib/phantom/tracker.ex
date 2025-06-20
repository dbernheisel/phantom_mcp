if Code.ensure_loaded?(Phoenix.Tracker) and Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Phantom.Tracker do
    @moduledoc """
    Track SSE streams so that notifications and messages can be sent to Streamable HTTP
    clients

    See `m:Phantom#module-persistent-streams` section for more information.
    """

    use Phoenix.Tracker

    def start_link(opts) do
      opts = Keyword.merge([name: __MODULE__], opts)
      Phoenix.Tracker.start_link(__MODULE__, opts, opts)
    end

    def init(opts) do
      server = Keyword.fetch!(opts, :pubsub_server)
      {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
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
end

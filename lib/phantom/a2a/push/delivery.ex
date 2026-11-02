defmodule Phantom.A2A.Push.Delivery do
  @moduledoc false
  # Delivers one event to one webhook, retrying with backoff. Between attempts
  # the process waits on a timer, so it stays responsive and stops cleanly.

  use GenServer, restart: :temporary

  require Logger

  alias Phantom.A2A.Push

  def start_link({config, event, opts, backoff}),
    do:
      GenServer.start_link(__MODULE__, %{
        config: config,
        event: event,
        opts: opts,
        backoff: backoff
      })

  @impl GenServer
  def init(state), do: {:ok, state, {:continue, :deliver}}

  @impl GenServer
  def handle_continue(:deliver, state), do: attempt(state)

  @impl GenServer
  def handle_info(:deliver, state), do: attempt(state)

  defp attempt(state) do
    case {Push.deliver(state.config, state.event, state.opts), state.backoff} do
      {:ok, _backoff} ->
        {:stop, :normal, state}

      {{:error, reason}, [delay | rest]} when not is_binary(reason) ->
        if retryable?(reason) do
          Process.send_after(self(), :deliver, delay)
          {:noreply, %{state | backoff: rest}}
        else
          give_up(state, reason)
        end

      {{:error, reason}, _backoff} ->
        give_up(state, reason)
    end
  end

  defp retryable?({:status, status}), do: status in [408, 429] or status >= 500
  defp retryable?(_network_error), do: true

  defp give_up(state, reason) do
    Logger.warning("A2A push to #{state.config.url} failed: #{inspect(reason)}")
    {:stop, :normal, state}
  end
end

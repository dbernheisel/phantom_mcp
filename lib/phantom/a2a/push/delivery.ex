defmodule Phantom.A2A.Push.Delivery do
  @moduledoc false
  # Delivers the events of one task to one webhook, in order and one at a time.

  use GenServer, restart: :temporary

  require Logger

  alias Phantom.A2A.Push

  @registry Phantom.A2A.PushRegistry
  @supervisor Phantom.A2A.PushSupervisor
  @max_queue 100

  def push(key, item, opts, backoff) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> enqueue(pid, key, item, opts, backoff)
      [] -> start(key, item, opts, backoff)
    end
  end

  defp start(key, {config, _event} = item, opts, backoff) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {key, item, opts, backoff}}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        enqueue(pid, key, item, opts, backoff)

      {:error, reason} ->
        Logger.warning("A2A push to #{redact(config.url)} dropped: #{inspect(reason)}")
    end
  end

  # The old process unregisters before it stops, so a failed call starts a new one.
  defp enqueue(pid, key, item, opts, backoff) do
    GenServer.call(pid, {:push, item})
  catch
    :exit, _reason -> start(key, item, opts, backoff)
  end

  def start_link({key, item, opts, backoff}) do
    state = %{
      key: key,
      queue: :queue.from_list([item]),
      opts: opts,
      retry_backoff: backoff,
      backoff: backoff,
      attempt: nil
    }

    GenServer.start_link(__MODULE__, state, name: {:via, Registry, {@registry, key}})
  end

  @impl GenServer
  def init(state), do: {:ok, state, {:continue, :deliver}}

  @impl GenServer
  def handle_call({:push, {config, _event} = item}, _from, state) do
    if :queue.len(state.queue) >= @max_queue do
      Logger.warning("A2A push to #{redact(config.url)} dropped: #{@max_queue} events waiting")
      {:reply, :ok, state}
    else
      {:reply, :ok, %{state | queue: :queue.in(item, state.queue)}}
    end
  end

  @impl GenServer
  def handle_continue(:deliver, state) do
    case :queue.peek(state.queue) do
      {:value, {config, event}} ->
        task =
          Task.Supervisor.async_nolink(Phantom.A2A.PushTasks, Push, :deliver, [
            config,
            event,
            state.opts
          ])

        {:noreply, %{state | attempt: {:task, task.ref}}}

      :empty ->
        Registry.unregister(@registry, state.key)
        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info({ref, result}, %{attempt: {:task, ref}} = state) do
    Process.demonitor(ref, [:flush])
    handle_result(result, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{attempt: {:task, ref}} = state),
    do: handle_result({:error, reason}, state)

  def handle_info(:retry, %{attempt: :waiting} = state),
    do: {:noreply, %{state | attempt: nil}, {:continue, :deliver}}

  defp handle_result(:ok, state), do: next(state)

  defp handle_result({:error, reason}, state) do
    case {retryable?(reason), state.backoff} do
      {true, [delay | rest]} ->
        Process.send_after(self(), :retry, delay)
        {:noreply, %{state | attempt: :waiting, backoff: rest}}

      _no_retry ->
        {:value, {config, _event}} = :queue.peek(state.queue)
        Logger.warning("A2A push to #{redact(config.url)} failed: #{inspect(reason)}")
        next(state)
    end
  end

  defp next(state) do
    state = %{
      state
      | queue: :queue.drop(state.queue),
        backoff: state.retry_backoff,
        attempt: nil
    }

    {:noreply, state, {:continue, :deliver}}
  end

  defp retryable?(reason) when is_binary(reason), do: false
  defp retryable?({:status, status}), do: status in [408, 429] or status >= 500
  defp retryable?(_network_error), do: true

  defp redact(url), do: URI.to_string(%{URI.parse(url) | query: nil, userinfo: nil})
end

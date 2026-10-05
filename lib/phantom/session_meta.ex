defmodule Phantom.SessionMeta do
  @moduledoc false
  # What a client declares in `initialize` (its capabilities and info), for
  # the protocol versions with sessions. Every node keeps a copy, so a request
  # on any node finds it, no matter which streams are open. Writes reach the
  # other nodes through the PubSub that `Phantom.Tracker` runs on.

  use GenServer

  @available Code.ensure_loaded?(Phoenix.PubSub)
  @table __MODULE__
  @topic "phantom:session_meta"
  @ttl :timer.hours(24)
  @sweep_interval :timer.minutes(1)
  @resubscribe_interval :timer.seconds(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Store metadata for a session on every node. Expires after `:ttl` ms without reads."
  def put(pubsub, session_id, meta, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @ttl)
    insert(session_id, meta, ttl)
    broadcast(pubsub, {:put, session_id, meta, ttl})
  end

  @doc "Read a session's metadata on this node, or `nil`."
  def get(session_id) do
    now = now()

    with true <- table?(),
         [{^session_id, meta, expires_at}] when expires_at > now <-
           :ets.lookup(@table, session_id) do
      :ets.update_element(@table, session_id, {3, now + @ttl})
      meta
    else
      _ -> nil
    end
  end

  @doc "Whether session metadata is kept on this node."
  def available?, do: table?()

  @doc "Remove a session's metadata from every node."
  def delete(pubsub, session_id) do
    if table?(), do: :ets.delete(@table, session_id)
    broadcast(pubsub, {:delete, session_id})
  end

  @doc "Receive other nodes' writes made through `pubsub`."
  def listen(pubsub) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:listen, pubsub}), else: :ok
  end

  @impl GenServer
  def init(nil) do
    # A PubSub's registry links to its subscribers, so its exit must not stop
    # this process.
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, MapSet.new()}
  end

  @impl GenServer
  def handle_call({:listen, pubsub}, _from, pubsubs) do
    subscribe(pubsub)
    {:reply, :ok, MapSet.put(pubsubs, pubsub)}
  end

  @impl GenServer
  def handle_info({__MODULE__, origin, message}, pubsubs) do
    if origin != node(), do: apply_message(message)
    {:noreply, pubsubs}
  end

  # A PubSub went down; subscribe again once it is back.
  def handle_info({:EXIT, _pid, _reason}, pubsubs) do
    Process.send_after(self(), :resubscribe, @resubscribe_interval)
    {:noreply, pubsubs}
  end

  def handle_info(:resubscribe, pubsubs) do
    if not Enum.all?(pubsubs, &subscribe/1),
      do: Process.send_after(self(), :resubscribe, @resubscribe_interval)

    {:noreply, pubsubs}
  end

  def handle_info(:sweep, pubsubs) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, pubsubs}
  end

  defp apply_message({:put, session_id, meta, ttl}), do: insert(session_id, meta, ttl)
  defp apply_message({:delete, session_id}), do: :ets.delete(@table, session_id)

  defp insert(session_id, meta, ttl) do
    if table?(), do: :ets.insert(@table, {session_id, meta, now() + ttl})
    :ok
  end

  # The table is absent when the application is not started, as in an escript.
  defp table?, do: :ets.whereis(@table) != :undefined

  defp now, do: System.monotonic_time(:millisecond)

  if @available do
    # Subscribing twice would deliver every write twice.
    defp subscribe(pubsub) do
      Phoenix.PubSub.unsubscribe(pubsub, @topic)
      Phoenix.PubSub.subscribe(pubsub, @topic) == :ok
    rescue
      ArgumentError -> false
    end

    defp broadcast(nil, _message), do: :ok

    defp broadcast(pubsub, message),
      do: Phoenix.PubSub.broadcast(pubsub, @topic, {__MODULE__, node(), message})
  else
    defp subscribe(_pubsub), do: true
    defp broadcast(_pubsub, _message), do: :ok
  end
end

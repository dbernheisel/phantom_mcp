defmodule Test.SessionStore do
  @moduledoc false
  # Mocks an app's session storage, as `Test.MCP.Router.connect/2` and
  # `terminate/1` use it: the `initialize` params of each session live in a
  # Mnesia table, so sessions survive a server restart and unknown or deleted
  # ones are answered with 404. The first node keeps the table on disk; the
  # others keep copies in memory.

  # Mnesia is not one of this project's applications.
  @compile {:no_warn_undefined, :mnesia}

  @table __MODULE__

  @doc "Start Mnesia with the table on `node()` (on disk in `:dir`) and `:nodes`."
  def start(opts \\ []) do
    others = Keyword.get(opts, :nodes, []) -- [node()]
    nodes = [node() | others]

    Application.put_env(:mnesia, :dir, String.to_charlist(Keyword.fetch!(opts, :dir)))
    :rpc.multicall(nodes, :mnesia, :stop, [])

    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_node, {:already_exists, _}}} -> :ok
    end

    {_results, []} = :rpc.multicall(nodes, :mnesia, :start, [])
    {:ok, _joined} = :mnesia.change_config(:extra_db_nodes, others)

    case :mnesia.create_table(@table,
           attributes: [:session_id, :params],
           disc_copies: [node()],
           ram_copies: others
         ) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, @table}} ->
        Enum.each(others, &:mnesia.add_table_copy(@table, &1, :ram_copies))
    end

    :ok = :mnesia.wait_for_tables([@table], :timer.seconds(10))
  end

  def stop, do: :mnesia.stop()

  def running? do
    :mnesia.system_info(:is_running) == :yes and @table in :mnesia.system_info(:local_tables)
  end

  def put(session_id, params), do: :mnesia.dirty_write({@table, session_id, params})

  def get(session_id) do
    case :mnesia.dirty_read(@table, session_id) do
      [{@table, ^session_id, params}] -> params
      [] -> nil
    end
  end

  def delete(session_id), do: :mnesia.dirty_delete(@table, session_id)
end

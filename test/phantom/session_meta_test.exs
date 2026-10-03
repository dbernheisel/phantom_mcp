defmodule Phantom.SessionMetaTest do
  use ExUnit.Case, async: true

  alias Phantom.SessionMeta

  setup context do
    {:ok, id: "session-meta-#{context.test}"}
  end

  test "stores and reads session metadata without PubSub", %{id: id} do
    assert SessionMeta.get(id) == nil
    :ok = SessionMeta.put(nil, id, %{client_capabilities: %{elicitation: %{}}})
    assert SessionMeta.get(id) == %{client_capabilities: %{elicitation: %{}}}
  end

  test "deletes session metadata", %{id: id} do
    :ok = SessionMeta.put(nil, id, %{client_info: %{"name" => "client"}})
    :ok = SessionMeta.delete(nil, id)
    assert SessionMeta.get(id) == nil
  end

  test "expires session metadata after its time to live", %{id: id} do
    :ok = SessionMeta.put(nil, id, %{client_info: %{}}, ttl: 0)
    assert SessionMeta.get(id) == nil
  end

  test "survives a PubSub it listens on going down" do
    pid = Process.whereis(SessionMeta)

    pubsub =
      start_supervised!(
        Supervisor.child_spec({Phoenix.PubSub, name: SessionMetaTest.PubSub}, id: :pubsub)
      )

    :ok = SessionMeta.listen(SessionMetaTest.PubSub)

    :ok = stop_supervised(:pubsub)
    refute Process.alive?(pubsub)

    :sys.get_state(SessionMeta)
    assert Process.whereis(SessionMeta) == pid
  end
end

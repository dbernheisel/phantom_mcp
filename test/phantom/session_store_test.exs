defmodule Phantom.SessionStoreTest do
  use ExUnit.Case

  import Phantom.TestDispatcher
  import Plug.Conn
  import Plug.Test

  setup context do
    start_supervised({Phoenix.PubSub, name: Test.PubSub})
    start_supervised({Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]})
    Phantom.Cache.register(Test.MCP.Router)

    dir = Path.join(System.tmp_dir!(), "phantom-sessions-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Test.SessionStore.stop()
      File.rm_rf(dir)
    end)

    :ok = Test.SessionStore.start(dir: dir)
    {:ok, dir: dir, test: context.test}
  end

  defp initialize do
    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{
        protocolVersion: "2025-11-25",
        capabilities: %{elicitation: %{}},
        clientInfo: %{name: "StoreClient", version: "1.0"}
      }
    })
    |> put_req_header("content-type", "application/json")
    |> call()

    assert_receive {:conn, %{status: 200} = conn}, 1_000
    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end

  test "restores a session's capabilities after the server forgets them", %{dir: dir} do
    session_id = initialize()

    # A restart empties Phantom's in-memory session metadata; the store's
    # disk copy survives it.
    Phantom.SessionMeta.delete(nil, session_id)
    Test.SessionStore.stop()
    :ok = Test.SessionStore.start(dir: dir)

    request_tool("elicit_tool", %{}, session_id: session_id, id: 2)
    assert_receive {:response, _id, "message", %{"method" => "elicitation/create"}}, 1_000
  end

  test "answers 404 for a session it does not know" do
    request_tool("echo_tool", %{message: "hi"}, session_id: "unknown-session", id: 3)
    assert_receive {:conn, %{status: 404}}, 1_000
  end

  test "answers 404 for a deleted session" do
    session_id = initialize()

    :delete
    |> conn("/mcp")
    |> call(%{session_id: session_id})

    assert_receive {:conn, %{status: status}} when status in 200..299, 1_000

    request_tool("echo_tool", %{message: "hi"}, session_id: session_id, id: 4)
    assert_receive {:conn, %{status: 404}}, 1_000
  end

  test "requests without a session are not checked" do
    request_tool("echo_tool", %{message: "hi"}, id: 5)
    assert_response(5, %{result: %{content: [%{text: "hi"}]}})
  end
end

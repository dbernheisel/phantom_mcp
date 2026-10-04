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

  describe "URL elicitation page" do
    test "completing the page notifies the session and lets the tool succeed" do
      session_id = initialize()
      request_sse_stream(session_id: session_id)
      assert_receive {:plug_conn, :sent}, 1_000

      request_tool("elicitation_required_tool", %{}, session_id: session_id, id: 7)

      assert_receive {:response, 7, "message",
                      %{
                        error: %{
                          code: -32042,
                          data: %{elicitations: [%{url: url, elicitationId: elicitation_id}]}
                        }
                      }},
                     1_000

      assert url =~ "/elicitations/#{elicitation_id}"

      page = page(:get, elicitation_id)
      assert page.status == 200
      assert page.resp_body =~ "Please authenticate first"

      assert page(:post, elicitation_id).status == 200

      assert_notify(%{
        method: "notifications/elicitation/complete",
        params: %{elicitationId: ^elicitation_id}
      })

      request_tool("elicitation_required_tool", %{}, session_id: session_id, id: 8)
      assert_response(8, %{result: %{content: [%{text: "Authenticated"}]}})
    end

    test "the page's form submits through the endpoint" do
      start_supervised!(
        {Test.Endpoint,
         url: [host: "localhost"],
         adapter: Bandit.PhoenixAdapter,
         render_errors: [formats: [json: Test.ErrorJSON], layout: false],
         pubsub_server: Test.PubSub,
         http: [ip: {127, 0, 0, 1}, port: 4045],
         server: true,
         secret_key_base: String.duplicate("a", 64)}
      )

      Test.ElicitationPage.start("form-session", "form-elicitation", "Sign in")

      # A browser submits an HTML form as application/x-www-form-urlencoded.
      response =
        Req.post!("http://127.0.0.1:4045/elicitations/form-elicitation",
          form: [],
          retry: false
        )

      assert response.status == 200
      assert Test.ElicitationPage.completed?("form-session")
    end

    test "an unknown elicitation is not found" do
      assert page(:get, "unknown").status == 404
      assert page(:post, "unknown").status == 404
    end

    defp page(method, elicitation_id) do
      method
      |> conn("/elicitations/#{elicitation_id}")
      |> Test.ElicitationPage.call(Test.ElicitationPage.init([]))
    end
  end
end

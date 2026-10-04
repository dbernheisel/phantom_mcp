defmodule Phantom.TestTest do
  use ExUnit.Case, async: false

  import Phantom.Test

  setup do
    start_supervised!({Phoenix.PubSub, name: TestFramework.PubSub})

    Phantom.Test.start(router: Test.MCP.Router, pubsub: TestFramework.PubSub)

    {:ok, session: build_session(Test.MCP.Router, pubsub: TestFramework.PubSub)}
  end

  describe "call_tool/3" do
    test "synchronous text reply", %{session: session} do
      session
      |> call_tool(:echo_tool, %{message: "hello"})
      |> assert_tool_text("hello")
    end

    test "asynchronous text reply via Session.respond/2", %{session: session} do
      session
      |> call_tool(:async_echo_tool, %{message: "later"}, timeout: 2_000)
      |> assert_tool_text("later")
    end

    test "tool error", %{session: session} do
      session
      |> call_tool(:with_error_tool, %{})
      |> assert_tool_error("an error")
    end

    test "image content", %{session: session} do
      session
      |> call_tool(:binary_tool, %{})
      |> assert_tool_image(mimeType: "image/png")
    end

    test "audio content", %{session: session} do
      session
      |> call_tool(:audio_tool, %{})
      |> assert_tool_audio(mimeType: "audio/wav")
    end

    test "validation failure surfaces as JSON-RPC error", %{session: session} do
      session
      |> call_tool(:validated_echo_tool, %{count: "not-a-number"})
      |> assert_jsonrpc_error(code: -32602)
    end

    test "elicitation_required tuple becomes JSON-RPC -32042", %{session: session} do
      session
      |> call_tool(:elicitation_required_tool, %{})
      |> assert_elicitation_required(message: ~r/authenticate/)
    end

    test "synchronous Session.elicit via expect_elicit", %{session: session} do
      expect_elicit(fn _elicit ->
        {:ok, %{"action" => "accept", "content" => %{"name" => "Joe"}}}
      end)

      session
      |> call_tool(:elicit_tool, %{})
      |> assert_tool_text(~r/Joe/)
    end

    test "expect_elicit_url responder for url-mode tools", %{session: session} do
      start_elicitation_pages()
      expect_elicit_url(&complete_page_and_accept/1)

      session
      |> call_tool(:url_elicit_tool, %{})
      |> assert_tool_text("Authenticated")
    end

    test "a url-mode tool waits for the page, not the client's accept",
         %{session: session} do
      start_elicitation_pages()
      put_page_timeout(50)
      expect_elicit_url(fn _elicit -> {:ok, %{"action" => "accept"}} end)

      session
      |> call_tool(:url_elicit_tool, %{})
      |> assert_tool_error("Authentication timed out")
    end

    test "embedded resource tool", %{session: session} do
      session
      |> call_tool(:embedded_resource_tool, %{})
      |> assert_tool_embedded_resource(mimeType: "image/png")
    end

    test "resource link tool", %{session: session} do
      session
      |> call_tool(:embedded_resource_link_tool, %{})
      |> assert_tool_resource_link(mimeType: "image/png")
    end
  end

  describe "read_resource/3" do
    test "synchronous text resource", %{session: session} do
      {:ok, _uri, content} = read_resource(session, :text_resource, id: 42)
      assert_resource_text(content, ~r/42/)
    end

    test "asynchronous blob resource", %{session: session} do
      result = read_resource(session, :binary_resource, [id: "bar"], timeout: 2_000)

      assert {:ok, _uri, content} = result
      assert_resource_blob(content, mime_type: "image/png")
    end
  end

  describe "get_prompt/3" do
    test "synchronous prompt", %{session: session} do
      session
      |> get_prompt(:text_prompt, %{code: "IO.puts(\"hi\")"})
      |> assert_prompt_message(role: :user, type: :text, text: ~r/IO\.puts/)
    end
  end

  describe "complete_prompt/4" do
    test "returns completion values", %{session: session} do
      assert %{completion: %{values: ~w[one two]}} =
               complete_prompt(session, :text_prompt, "code", "")
    end
  end

  describe "complete_resource/4" do
    test "completes against a URI template", %{session: session} do
      assert %{completion: %{values: ~w[foo bar]}} =
               complete_resource(session, "myapp:///binary/{id}", "id", "")
    end
  end

  describe "list_resources/2" do
    test "returns paginated resource links", %{session: session} do
      result = list_resources(session)
      assert %{resources: links, nextCursor: cursor} = result
      assert length(links) == 100
      assert is_binary(cursor)
    end
  end

  describe "side-channel notifications" do
    test "client log is captured", %{session: session} do
      call_tool(session, :client_log_tool, %{message: "yo"})
      assert_client_log_seen(level: :info, data: %{message: "yo"})
    end

    test "progress notifications during long async tool", %{session: session} do
      call_tool(session, :really_long_async_tool, %{message: "done"},
        timeout: 5_000,
        progress_token: "tok"
      )
      |> assert_tool_text("done")

      assert_progress_seen(steps: 4, total: 4)
    end

    test "refute_progress_seen passes when no progress emitted", %{session: session} do
      call_tool(session, :echo_tool, %{message: "hi"})
      refute_progress_seen()
    end
  end

  describe "build_session/2 allow-lists" do
    test "filtered tool is invisible to dispatcher", %{session: _} do
      session =
        build_session(Test.MCP.Router,
          pubsub: TestFramework.PubSub,
          allowed_tools: ["echo_tool"]
        )

      session
      |> call_tool(:with_error_tool, %{})
      |> assert_jsonrpc_error(code: -32602)
    end
  end

  describe "mailbox isolation" do
    test "non-Phantom $gen_cast messages survive a dispatch", %{session: session} do
      GenServer.cast(self(), {:hello_from_someone_else, 42})

      call_tool(session, :echo_tool, %{message: "hi"})
      |> assert_tool_text("hi")

      assert_received {:"$gen_cast", {:hello_from_someone_else, 42}}
    end
  end

  describe "TimeoutError" do
    defmodule SilentHandler do
      def silent_tool(_params, session), do: {:noreply, session}
    end

    test "raises if async response doesn't arrive in time", %{session: session} do
      Phantom.Cache.add_tool(Test.MCP.Router, %{
        name: "silent_tool",
        handler: SilentHandler,
        function: :silent_tool,
        description: "never responds"
      })

      assert_raise Phantom.Test.TimeoutError, ~r/no response/, fn ->
        call_tool(session, :silent_tool, %{}, timeout: 50)
      end
    end
  end

  describe "MCP 2026-07-28 sessions" do
    setup do
      {:ok,
       session:
         build_session(Test.MCP.Router,
           pubsub: TestFramework.PubSub,
           protocol_version: "2026-07-28",
           log_level: "debug"
         )}
    end

    test "requests use the stateless protocol", %{session: session} do
      assert Phantom.Session.stateless?(session)
    end

    test "re-entry elicitation is answered by expect_elicit", %{session: session} do
      expect_elicit(fn %Phantom.Elicit{message: "Your name?"} ->
        {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}}
      end)

      session
      |> call_tool(:resume_tool, %{origin: "stateless"})
      |> assert_tool_text("resumed name=Ada origin=stateless")
    end

    test "input_required is returned when no responder is registered", %{session: session} do
      assert %{resultType: "input_required", inputRequests: %{"elicitation" => _}} =
               call_tool(session, :resume_tool, %{})
    end

    test "elicitation from a Task spawned by the handler suspends and resumes",
         %{session: session} do
      expect_elicit(fn _elicit ->
        {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}}
      end)

      session
      |> call_tool(:async_elicit_tool, %{})
      |> assert_tool_text(~s({"hello":"async my name is Ada"}))
    end

    test "elicitation without options waits inline, as under older protocols",
         %{session: session} do
      expect_elicit(fn _elicit ->
        {:ok,
         %{
           "action" => "accept",
           "content" => %{"name" => "Ada", "email" => "ada@example.com", "role" => "dev"}
         }}
      end)

      session
      |> call_tool(:elicit_tool, %{})
      |> assert_tool_text(~s({"hello":"my name is Ada"}))
    end

    test "elicitation_required succeeds once the user completes the page",
         %{session: session} do
      start_elicitation_pages()

      expect_elicit_url(&complete_page_and_accept/1)

      session
      |> call_tool(:elicitation_required_tool, %{})
      |> assert_tool_text("Authenticated")
    end

    test "a url-mode tool waits inline for the page", %{session: session} do
      start_elicitation_pages()
      expect_elicit_url(&complete_page_and_accept/1)

      session
      |> call_tool(:url_elicit_tool, %{})
      |> assert_tool_text("Authenticated")
    end

    test "accepting elicitation_required without completing the page asks again",
         %{session: session} do
      start_elicitation_pages()
      test = self()

      # Accepting is consent to open the URL, not proof the user finished.
      expect_elicit_url(fn _elicit ->
        send(test, :asked)
        {:ok, %{"action" => "accept"}}
      end)

      assert_raise RuntimeError, ~r/still required input/, fn ->
        call_tool(session, :elicitation_required_tool, %{})
      end

      assert_received :asked
      assert_received :asked
    end

    test "a cancelled elicitation_required ends the call", %{session: session} do
      expect_elicit_url(fn _elicit -> {:ok, %{"action" => "cancel"}} end)

      session
      |> call_tool(:elicitation_required_tool, %{})
      |> assert_tool_error("The client did not complete the requested elicitation")
    end

    test "a prompt's input_required ends when the client cancels", %{session: session} do
      expect_elicit(fn _elicit -> {:ok, %{"action" => "cancel"}} end)

      assert {:jsonrpc_error, %{message: "The client did not provide context"}} =
               get_prompt(session, :input_required_prompt, %{})
    end

    test "await: true suspends the handler and resumes it", %{session: session} do
      expect_elicit(fn _elicit ->
        {:ok, %{"action" => "accept", "content" => %{"color" => "red"}}}
      end)

      session
      |> call_tool(:await_tool, %{})
      |> assert_tool_text("awaited color=red")
    end

    test "client logs are captured", %{session: session} do
      call_tool(session, :client_log_tool, %{message: "modern"})
      assert_client_log_seen(level: :info, data: %{message: "modern"})
    end
  end

  # Stands in for the user finishing the page the client opened.
  defp complete_page_and_accept(%Phantom.Elicit{url: url}) do
    url |> String.split("/") |> List.last() |> Test.ElicitationPage.complete()
    {:ok, %{"action" => "accept"}}
  end

  defp put_page_timeout(timeout) do
    Application.put_env(:phantom_mcp, :elicitation_page_timeout, timeout)
    on_exit(fn -> Application.delete_env(:phantom_mcp, :elicitation_page_timeout) end)
  end

  defp start_elicitation_pages do
    dir = Path.join(System.tmp_dir!(), "phantom-pages-#{System.unique_integer([:positive])}")
    :ok = Test.SessionStore.start(dir: dir)

    on_exit(fn ->
      Test.SessionStore.stop()
      File.rm_rf(dir)
    end)
  end
end

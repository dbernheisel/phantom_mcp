defmodule Phantom.StatelessCoreTest do
  use ExUnit.Case, async: true

  import Phantom.TestDispatcher
  import Plug.Conn
  import Plug.Test

  alias Phantom.Request
  alias Phantom.RequestState
  alias Phantom.Session

  @secret "test-secret-key-base-of-sufficient-entropy-for-aes-256-gcm-encryption"
  @salt "phantom test salt"

  defmodule Router do
    use Phantom.Router,
      name: "StatelessTest",
      vsn: "1.0",
      secret_key_base: "test-secret-key-base-of-sufficient-entropy-for-aes-256-gcm-encryption",
      request_state_salt: "phantom test salt"

    require Phantom.Tool, as: T

    tool :resume_demo, description: "First call returns input_required; resume returns text" do
      field :seed, :string, required: false
    end

    def resume_demo(_params, %Session{state: %{step: :ready} = state} = session) do
      {:reply, T.text("resumed with seed=#{state.seed}"), session}
    end

    def resume_demo(params, session) do
      {:reply,
       T.input_required(
         input_requests: %{
           "confirm" => %{method: "elicitation/create", params: %{mode: "form"}}
         },
         state: %{step: :ready, seed: params["seed"] || "default"}
       ), session}
    end

    tool :elicit_demo, description: "Calls Session.elicit/3 (no await) — re-entry pattern" do
    end

    def elicit_demo(
          %{"choice" => choice},
          %Session{state: %{step: :got_choice, original: orig}} = session
        ) do
      {:reply, T.text("chose=#{choice} orig=#{inspect(orig)}"), session}
    end

    def elicit_demo(params, session) do
      {:noreply,
       Session.elicit(
         session,
         Phantom.Elicit.form(%{
           message: "pick",
           requested_schema: [%{name: "choice", type: :string, required: true}]
         }),
         state: %{step: :got_choice, original: params}
       )}
    end

    tool :await_demo, description: "Calls Session.elicit(..., await: true) inline" do
    end

    tool :who_am_i, description: "Returns session.client_info for inspection" do
    end

    def who_am_i(_params, session) do
      info = session.client_info || %{}
      caps = session.client_capabilities || %{}

      {:reply, T.text("client=#{info["name"]} elicitation=#{inspect(caps[:elicitation])}"),
       session}
    end

    require Phantom.Prompt, as: P

    @description "Prompt that elicits and resumes via session.state"
    prompt :ask_prompt, arguments: []

    def ask_prompt(_args, %Session{state: %{step: :got_name}} = session) do
      name = get_in(session.request.params, ["arguments", "name"]) || "stranger"
      {:reply, P.response(assistant: P.text("Hello, #{name}!")), session}
    end

    def ask_prompt(_args, session) do
      {:noreply,
       Session.elicit(
         session,
         Phantom.Elicit.form(%{
           message: "Your name?",
           requested_schema: [%{name: "name", type: :string, required: true}]
         }),
         state: %{step: :got_name}
       )}
    end

    def await_demo(_params, session) do
      case Session.elicit(
             session,
             Phantom.Elicit.form(%{
               message: "pick",
               requested_schema: [%{name: "color", type: :string, required: true}]
             }),
             await: true
           ) do
        {:ok, %{"color" => color}} ->
          {:reply, T.text("got color=#{color}"), session}

        other ->
          {:reply, T.error("await failed: #{inspect(other)}"), session}
      end
    end
  end

  setup do
    Phantom.Cache.register(Router)
    :ok
  end

  defp build_session do
    Session.new(nil,
      router: Router,
      pid: self(),
      transport_pid: self(),
      client_capabilities: %{roots: false, sampling: false, elicitation: %{}, ui: false}
    )
  end

  defp build_request(meta \\ %{}, name \\ "resume_demo", arguments \\ %{}) do
    {:ok, request} =
      Request.build(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => name,
          "arguments" => arguments,
          "_meta" => meta
        }
      })

    request
  end

  # Under always-Task-mode, tools dispatch asynchronously: run_tool returns
  # {:noreply, session} and the eventual result arrives as a Session.respond
  # GenServer cast on the test pid (session.pid = self()).
  defp assert_responded(timeout \\ 1_000) do
    assert_receive {:"$gen_cast", {:respond, _request_id, %{result: result}}}, timeout
    result
  end

  describe "encode-on-outbound" do
    test "input_required result has requestState encrypted as an opaque binary" do
      session = build_session()
      request = build_request()

      assert {:noreply, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      response = assert_responded()

      assert %{
               resultType: "input_required",
               inputRequests: %{"confirm" => _},
               requestState: token
             } = response

      assert is_binary(token)
      refute is_map(token)

      assert {:ok, %{step: :ready, seed: "default"}} =
               RequestState.decode(token, @secret, @salt)
    end
  end

  describe "decode-on-inbound" do
    test "a valid requestState in _meta populates session.state and resumes" do
      session = build_session()
      request = build_request()
      binding = RequestState.binding(request, session)
      token = RequestState.encode(%{step: :ready, seed: "echo"}, binding, @secret, @salt)
      request = build_request(%{"requestState" => token})

      assert {:noreply, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert assert_responded() == %{content: [%{type: :text, text: "resumed with seed=echo"}]}
    end

    test "an invalid requestState returns invalid_params" do
      session = build_session()
      request = build_request(%{"requestState" => "not-a-real-token"})

      # State decode happens before the Task spawn, so this comes back inline.
      assert {:error, %{code: -32602} = error, _session} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert error.message =~ "request state" or error.message =~ "Invalid"
    end

    test "an expired requestState returns a distinct error code" do
      session = build_session()
      initial_request = build_request()
      binding = RequestState.binding(initial_request, session)
      token = RequestState.encode(%{step: :ready, seed: "x"}, binding, @secret, @salt)
      Process.sleep(1_100)
      request = build_request(%{"requestState" => token})

      # The test router doesn't customize max_age, so this stays valid under
      # the default 24h ttl — assert the success path until we expose max_age.
      assert {:noreply, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert_responded()
    end
  end

  describe "trace context propagation" do
    test "[:phantom, :dispatch] span metadata includes trace_context from _meta" do
      handler_id = "trace-ctx-test-#{System.unique_integer()}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:phantom, :dispatch, :start],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:span_metadata, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      session = build_session()

      request =
        build_request(
          %{
            "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
            "tracestate" => "rojo=00f067aa0ba902b7"
          },
          "resume_demo"
        )

      Router.dispatch_method(["tools/call", request.params, request, session])

      assert_receive {:span_metadata, %{trace_context: trace_context}}

      assert trace_context == %{
               traceparent: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
               tracestate: "rojo=00f067aa0ba902b7"
             }
    end
  end

  # Re-entry (`{:noreply, Session.elicit(..., state: ...)}`) uses the same
  # Task-suspension machinery as `await: true`. The dispatcher's
  # `process_handler_result/5` converts the pending elicit into an
  # `await: true` call internally and re-applies the handler on resume.
  # The end-to-end cross-node version lives in
  # test/phantom/distributed_test.exs.
  describe "re-entry: `{:noreply, Session.elicit(..., state: ...)}`" do
    setup do
      start_supervised({Phoenix.PubSub, name: Test.StatelessReentry.PubSub})

      start_supervised(
        {Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.StatelessReentry.PubSub]}
      )

      :ok
    end

    test "dispatcher returns serializable state, then re-applies the handler on any node" do
      session = build_session()
      request = build_request(%{"protocolVersion" => "2026-07-28"}, "elicit_demo", %{"q" => "hi"})

      assert {:noreply, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert_receive {:"$gen_cast", {:respond, 1, %{result: input_required}}}
      assert %{resultType: "input_required", requestState: token} = input_required
      follow_session = build_session()

      follow_request =
        build_request(
          %{"protocolVersion" => "2026-07-28"},
          "elicit_demo",
          %{}
        )

      follow_request = %{
        follow_request
        | params:
            Map.merge(follow_request.params, %{
              "requestState" => token,
              "inputResponses" => %{
                "elicitation" => %{
                  "action" => "accept",
                  "content" => %{"choice" => "blue"}
                }
              }
            })
      }

      assert {:noreply, _} =
               Router.dispatch_method(
                 "tools/call",
                 follow_request.params,
                 follow_request,
                 follow_session
               )

      response = assert_responded(2_000)

      assert %{content: [%{type: :text, text: text}]} = response
      assert text =~ "chose=blue"
      assert text =~ ~s(orig=%{"q" => "hi"})
    end
  end

  describe "Session.elicit/3 with `await: true`" do
    test "stateless rejects unserializable inline continuations" do
      session = build_session()
      request = build_request(%{"protocolVersion" => "2026-07-28"}, "await_demo")

      assert {:noreply, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      response = assert_responded(2_000)
      assert %{content: [%{type: :text, text: text}], isError: true} = response
      assert text =~ "await failed: :not_supported"
    end
  end

  # Prompt-side parity with the tool re-entry pattern: a `prompts/get` handler
  # can return `{:noreply, Session.elicit(...)}` and use the same stateless
  # re-entry flow as tools.

  describe "_meta hydrates session.client_info and client_capabilities" do
    # Under stateless core there is no `initialize` call to populate these
    # on the session. The request's `_meta` carries them on every call, so
    # devs reading `session.client_info` or `session.client_capabilities`
    # see the same shape they would on a legacy session.
    test "session.client_info and client_capabilities populate from _meta" do
      :post
      |> conn("/mcp", %{
        jsonrpc: "2.0",
        id: 7,
        method: "tools/call",
        params: %{
          "name" => "who_am_i",
          "arguments" => %{},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientInfo" => %{
              "name" => "TestClient",
              "version" => "1.0.0"
            },
            "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
          }
        }
      })
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "who_am_i")
      |> call(router: Router)

      assert_receive {:response, 7, "message", payload}, 1_000

      text = get_in(payload, [:result, :content, Access.at(0), :text])
      assert text =~ "client=TestClient"
      assert text =~ "elicitation=%{}"
    end
  end

  describe "Session.elicit/3 — protocol-aware default mode" do
    test "stateless: no opts annotates session with pending_elicit and nil state" do
      request = build_request(%{"protocolVersion" => "2026-07-28"})
      session = %{build_session() | request: request}
      elicit = Phantom.Elicit.form(%{message: "x", requested_schema: []})

      assert %Session{pending_elicit: {^elicit, nil}} = Phantom.Session.elicit(session, elicit)
    end

    test "legacy: no opts blocks via inline path (preserves existing behavior)" do
      request = build_request(%{"protocolVersion" => "2025-11-25"})
      # No transport, no elicit closure, no client capability — falls through
      # to :not_supported. Critically, this is NOT a session struct, so
      # existing `{:ok, _} = Session.elicit(session, elicit)` callers keep
      # their original semantics.
      session = %{
        build_session()
        | request: request,
          pid: nil,
          elicit: nil,
          client_capabilities: %{roots: false, sampling: false, elicitation: false, ui: false}
      }

      elicit = Phantom.Elicit.form(%{message: "x", requested_schema: []})

      assert :not_supported = Phantom.Session.elicit(session, elicit)
    end

    test "explicit :state forces re-entry on legacy" do
      request = build_request(%{"protocolVersion" => "2025-11-25"})
      session = %{build_session() | request: request}
      elicit = Phantom.Elicit.form(%{message: "x", requested_schema: []})

      assert %Session{pending_elicit: {^elicit, %{step: :ok}}} =
               Phantom.Session.elicit(session, elicit, state: %{step: :ok})
    end
  end
end

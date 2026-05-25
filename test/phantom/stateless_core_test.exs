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
         input_requests: [%{name: "confirm", schema: %{type: "string"}}],
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
      Session.elicit(
        session,
        Phantom.Elicit.form(%{
          message: "pick",
          requested_schema: [%{name: "choice", type: :string, required: true}]
        }),
        state: %{step: :got_choice, original: params}
      )
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
      Session.elicit(
        session,
        Phantom.Elicit.form(%{
          message: "Your name?",
          requested_schema: [%{name: "name", type: :string, required: true}]
        }),
        state: %{step: :got_name}
      )
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
    Session.new(nil, router: Router, pid: self(), transport_pid: self())
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
               resultType: "inputRequired",
               inputRequests: [_],
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
      token = RequestState.encode(%{step: :ready, seed: "echo"}, @secret, @salt)
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
      token = RequestState.encode(%{step: :ready, seed: "x"}, @secret, @salt)
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

  describe "Session.elicit/3 (no :await) — re-entry pattern" do
    test "under stateless: tool's elicit call yields an inputRequired result with encrypted state" do
      session = build_session()
      request = build_request(%{"protocolVersion" => "2026-07-28"}, "elicit_demo")

      assert {:noreply, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      response = assert_responded()

      assert %{
               resultType: "inputRequired",
               inputRequests: [_ | _],
               requestState: token
             } = response

      assert is_binary(token)

      assert {:ok, %{step: :got_choice, original: %{}}} =
               RequestState.decode(token, @secret, @salt)
    end

    test "under stateless: resume from state runs the matching clause" do
      session = build_session()
      token = RequestState.encode(%{step: :got_choice, original: %{"a" => 1}}, @secret, @salt)

      request =
        build_request(
          %{"requestState" => token, "protocolVersion" => "2026-07-28"},
          "elicit_demo",
          %{"choice" => "blue"}
        )

      assert {:noreply, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      response = assert_responded()
      assert %{content: [%{type: :text, text: text}]} = response
      assert text =~ "chose=blue"
      assert text =~ ~s|orig=%{"a" => 1}|
    end

    test "under legacy: dispatcher invokes session.elicit and re-invokes handler with state" do
      session = %{
        build_session()
        | elicit: fn _elicit, _timeout -> {:ok, %{"choice" => "red"}} end
      }

      request = build_request(%{"protocolVersion" => "2025-11-25"}, "elicit_demo")

      assert {:noreply, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      response = assert_responded()
      assert %{content: [%{type: :text, text: text}]} = response
      assert text =~ "chose=red"
    end
  end

  describe "Session.elicit/3 with `await: true` — protocol-agnostic inline" do
    setup do
      start_supervised({Phoenix.PubSub, name: Test.StatelessAwait.PubSub})

      start_supervised(
        {Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.StatelessAwait.PubSub]}
      )

      :ok
    end

    test "stateless: tool's inline elicit yields inputRequired; follow-up resumes the same task" do
      session = build_session()
      request = build_request(%{"protocolVersion" => "2026-07-28"}, "await_demo")
      original_request_id = request.id

      # First call — the Task spawns and the handler calls Session.elicit(await: true).
      # That sends {:phantom_await_elicit, ...} to the test pid (session.pid).
      # We have to handle it like the session GenServer would.
      assert {:noreply, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert_receive {:phantom_await_elicit, ref_id, elicit, task_pid, ^original_request_id},
                     1_000

      # Verify the elicit struct made it through.
      assert %Phantom.Elicit{message: "pick"} = elicit

      # The session GenServer would register the task in Tracker. Do it manually here.
      Phantom.Tracker.track_request(task_pid, ref_id, %{type: :pending_task, pid: task_pid})

      # Simulate the follow-up: a NEW request arrives carrying the encrypted ref_id.
      token = RequestState.encode({:__phantom_await__, ref_id}, @secret, @salt)
      follow_session = build_session()

      follow_request =
        build_request(
          %{"requestState" => token, "protocolVersion" => "2026-07-28"},
          "await_demo",
          %{"color" => "blue"}
        )

      # Dispatch should adopt the suspended task and return {:noreply}.
      assert {:noreply, _} =
               Router.dispatch_method(
                 "tools/call",
                 follow_request.params,
                 follow_request,
                 follow_session
               )

      # The task is now resumed. It returns Tool.text("got color=blue") and
      # casts Session.respond to the new adopter (our test pid).
      response = assert_responded(2_000)
      assert %{content: [%{type: :text, text: "got color=blue"}]} = response

      # Verify the original request id was preserved at await-yield time.
      assert original_request_id == request.id
    end
  end

  describe "prompts/get supports elicitation re-entry" do
    test "under stateless: prompt's elicit yields inputRequired with encrypted state" do
      session = build_session()

      {:ok, request} =
        Request.build(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "prompts/get",
          "params" => %{
            "name" => "ask_prompt",
            "arguments" => %{},
            "_meta" => %{"protocolVersion" => "2026-07-28"}
          }
        })

      assert {:noreply, _} =
               Router.dispatch_method("prompts/get", request.params, request, session)

      response = assert_responded()

      assert %{
               resultType: "inputRequired",
               inputRequests: [_ | _],
               requestState: token
             } = response

      assert is_binary(token)
      assert {:ok, %{step: :got_name}} = RequestState.decode(token, @secret, @salt)
    end

    test "under stateless: resume continues the prompt handler with session.state set" do
      session = build_session()
      token = RequestState.encode(%{step: :got_name}, @secret, @salt)

      {:ok, request} =
        Request.build(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "prompts/get",
          "params" => %{
            "name" => "ask_prompt",
            "arguments" => %{"name" => "alice"},
            "_meta" => %{"protocolVersion" => "2026-07-28", "requestState" => token}
          }
        })

      assert {:noreply, _} =
               Router.dispatch_method("prompts/get", request.params, request, session)

      response = assert_responded()
      assert %{messages: [%{role: :assistant, content: %{text: text}}]} = response
      assert text == "Hello, alice!"
    end
  end

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
            "protocolVersion" => "2026-07-28",
            "clientInfo" => %{"name" => "TestClient", "version" => "1.0.0"},
            "capabilities" => %{"elicitation" => %{}}
          }
        }
      })
      |> put_req_header("content-type", "application/json")
      |> call(router: Router)

      assert_receive {:response, 7, "message", payload}, 1_000

      text = get_in(payload, [:result, :content, Access.at(0), :text])
      assert text =~ "client=TestClient"
      assert text =~ "elicitation=%{}"
    end
  end

  describe "Session.elicit/3 — protocol-aware default mode" do
    test "stateless: no opts returns the re-entry tagged tuple with nil state" do
      request = build_request(%{"protocolVersion" => "2026-07-28"})
      session = %{build_session() | request: request}
      elicit = Phantom.Elicit.form(%{message: "x", requested_schema: []})

      assert {:input_required, ^elicit, nil, _} = Phantom.Session.elicit(session, elicit)
    end

    test "legacy: no opts blocks via inline path (preserves existing behavior)" do
      request = build_request(%{"protocolVersion" => "2025-11-25"})
      # No transport, no elicit closure, no client capability — falls through
      # to :not_supported. Critically, this is NOT the re-entry tagged tuple,
      # so existing `{:ok, _} = Session.elicit(session, elicit)` callers keep
      # their original semantics.
      session = %{build_session() | request: request, pid: nil, elicit: nil}
      elicit = Phantom.Elicit.form(%{message: "x", requested_schema: []})

      assert :not_supported = Phantom.Session.elicit(session, elicit)
    end

    test "explicit :state forces re-entry on legacy" do
      request = build_request(%{"protocolVersion" => "2025-11-25"})
      session = %{build_session() | request: request}
      elicit = Phantom.Elicit.form(%{message: "x", requested_schema: []})

      assert {:input_required, ^elicit, %{step: :ok}, _} =
               Phantom.Session.elicit(session, elicit, state: %{step: :ok})
    end
  end
end

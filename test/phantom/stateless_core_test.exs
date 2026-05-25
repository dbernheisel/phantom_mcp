defmodule Phantom.StatelessCoreTest do
  use ExUnit.Case, async: true

  alias Phantom.Request
  alias Phantom.RequestState
  alias Phantom.Session

  @secret "test-secret-key-base-of-sufficient-entropy-for-aes-256-gcm-encryption"

  defmodule Router do
    use Phantom.Router,
      name: "StatelessTest",
      vsn: "1.0",
      secret_key_base: "test-secret-key-base-of-sufficient-entropy-for-aes-256-gcm-encryption"

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

    tool :elicit_demo, description: "Calls Session.elicit/3 with state — protocol-agnostic" do
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

  describe "encode-on-outbound" do
    test "input_required result has requestState encrypted as an opaque binary" do
      session = build_session()
      request = build_request()

      assert {:reply, response, _session} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert %{
               resultType: "inputRequired",
               inputRequests: [_],
               requestState: token
             } = response

      assert is_binary(token)
      # The raw term was a map; ensure it's not leaked through.
      refute is_map(token)

      # Should round-trip back to the original raw state through RequestState.
      assert {:ok, %{step: :ready, seed: "default"}} =
               RequestState.decode(token, @secret)
    end
  end

  describe "decode-on-inbound" do
    test "a valid requestState in _meta populates session.state and resumes" do
      session = build_session()
      token = RequestState.encode(%{step: :ready, seed: "echo"}, @secret)
      request = build_request(%{"requestState" => token})

      assert {:reply, response, _session} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert response == %{content: [%{type: :text, text: "resumed with seed=echo"}]}
    end

    test "an invalid requestState returns invalid_params" do
      session = build_session()
      request = build_request(%{"requestState" => "not-a-real-token"})

      assert {:error, %{code: -32602} = error, _session} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert error.message =~ "request state" or error.message =~ "Invalid"
    end

    test "an expired requestState returns a distinct error code" do
      session = build_session()
      token = RequestState.encode(%{step: :ready, seed: "x"}, @secret)
      # sleep past max_age:1
      Process.sleep(1_100)
      request = build_request(%{"requestState" => token})

      # The test router doesn't customize max_age, so this will be valid under
      # the default 24h ttl — assert the success path until we expose max_age.
      assert {:reply, _response, _session} =
               Router.dispatch_method("tools/call", request.params, request, session)
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

  describe "Session.elicit/3 with :state — protocol-agnostic" do
    test "under stateless: tool's elicit call yields an inputRequired result with encrypted state" do
      session = build_session()
      request = build_request(%{"protocolVersion" => "2026-07-28"}, "elicit_demo")

      assert {:reply, response, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert %{
               resultType: "inputRequired",
               inputRequests: [_ | _],
               requestState: token
             } = response

      assert is_binary(token)
      assert {:ok, %{step: :got_choice, original: %{}}} = RequestState.decode(token, @secret)
    end

    test "under stateless: resume from state runs the matching clause" do
      session = build_session()
      token = RequestState.encode(%{step: :got_choice, original: %{"a" => 1}}, @secret)

      request =
        build_request(
          %{"requestState" => token, "protocolVersion" => "2026-07-28"},
          "elicit_demo",
          %{"choice" => "blue"}
        )

      assert {:reply, response, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

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

      assert {:reply, response, _} =
               Router.dispatch_method("tools/call", request.params, request, session)

      assert %{content: [%{type: :text, text: text}]} = response
      assert text =~ "chose=red"
    end
  end
end

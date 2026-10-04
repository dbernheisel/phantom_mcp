defmodule Phantom.ProgressRefTest do
  use ExUnit.Case, async: true

  alias Phantom.Request
  alias Phantom.Session

  @pubsub Phantom.ProgressRefTest.PubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    :ok
  end

  defp session(params) do
    request = %Request{id: "req-1", method: "tools/call", params: params}
    Session.new("session-1", pubsub: @pubsub, pid: self(), request: request)
  end

  describe "progress_ref/1" do
    test "is a JSON-safe reference to the request" do
      ref = Session.progress_ref(session(%{"_meta" => %{"progressToken" => "tok"}}))

      assert ref == %{
               "pubsub" => "Elixir.Phantom.ProgressRefTest.PubSub",
               "session_id" => "session-1",
               "request_id" => "req-1",
               "progress_token" => "tok"
             }

      assert ref |> JSON.encode!() |> JSON.decode!() == ref
    end

    test "is nil when the client did not ask for progress" do
      assert Session.progress_ref(session(%{})) == nil
    end

    test "is nil without PubSub" do
      session = %{session(%{"_meta" => %{"progressToken" => "tok"}}) | pubsub: nil}
      assert Session.progress_ref(session) == nil
    end
  end

  describe "notify_progress/4 with a progress ref" do
    test "reaches the request's stream through PubSub" do
      ref = Session.progress_ref(session(%{"_meta" => %{"progressToken" => "tok"}}))
      Phantom.Tracker.subscribe_request(@pubsub, "session-1", "req-1")

      assert :ok = Session.notify_progress(ref, 50, 100, "Halfway")
      assert_receive {:"$gen_cast", {:progress, "tok", 50, 100, "Halfway"}}
    end

    test "works after a JSON round trip" do
      ref =
        session(%{"_meta" => %{"progressToken" => 7}})
        |> Session.progress_ref()
        |> JSON.encode!()
        |> JSON.decode!()

      Phantom.Tracker.subscribe_request(@pubsub, "session-1", "req-1")

      assert :ok = Session.notify_progress(ref, 1)
      assert_receive {:"$gen_cast", {:progress, 7, 1, nil, nil}}
    end

    test "does nothing for a nil ref" do
      assert :ok = Session.notify_progress(nil, 50, 100, "Halfway")
    end
  end
end

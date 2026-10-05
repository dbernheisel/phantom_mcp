defmodule Phantom.SessionCallTest do
  use ExUnit.Case, async: true

  @pubsub Phantom.SessionCallTest.PubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    :ok
  end

  defp start_stream(session_id, delay) do
    spawn_link(fn ->
      Process.sleep(delay)
      Phantom.Tracker.subscribe_session(@pubsub, session_id)

      receive do
        {:"$gen_call", from, message} -> GenServer.reply(from, {:handled, message})
      end

      Process.sleep(:infinity)
    end)
  end

  test "reaches a session stream that subscribes after the call starts" do
    start_stream("late", 300)

    assert Phantom.Tracker.call_session(@pubsub, "late", :set_level, 2_000) ==
             {:handled, :set_level}
  end

  test "returns the first reply once" do
    start_stream("ready", 0)
    Process.sleep(50)

    assert Phantom.Tracker.call_session(@pubsub, "ready", :set_level, 2_000) ==
             {:handled, :set_level}

    refute_receive _
  end

  test "is an error when no stream answers in time" do
    assert Phantom.Tracker.call_session(@pubsub, "missing", :set_level, 300) == :error
  end
end

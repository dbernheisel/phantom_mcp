defmodule Phantom.SessionInactivityTest do
  use ExUnit.Case, async: true

  alias Phantom.Request
  alias Phantom.Session

  @timeout to_timeout(second: 30)

  defp start_session(ctx, opts \\ []) do
    observer = self()

    session =
      Session.new(Atom.to_string(ctx.test),
        requests: %{1 => %Request{id: 1}},
        request: opts[:request],
        close_after_complete: Keyword.get(opts, :close_after_complete, true)
      )

    continue = fn state ->
      send(observer, {:initial_timer, state.timer})
      state
    end

    start_supervised!(
      {Task,
       fn ->
         Session.start_loop(
           session: session,
           timeout: Keyword.get(opts, :timeout, @timeout),
           continue_fun: continue,
           stream_fun: fn state, id, event, payload ->
             send(observer, {:stream, id, event, payload})
             state
           end
         )
       end}
    )
  end

  test "initial dispatch replaces its timer instead of leaving two running", ctx do
    pid = start_session(ctx)
    state = :sys.get_state(pid)
    assert_receive {:initial_timer, first}

    assert first != state.timer
    assert Process.read_timer(first) == false
    assert is_integer(Process.read_timer(state.timer))
  end

  test "progress replaces the timer and ignores its queued timeout", ctx do
    pid = start_session(ctx)
    before = :sys.get_state(pid)

    Session.notify_progress(pid, "token", 1, 2, "working")
    send(pid, {:timeout, before.timer, :inactivity})
    state = :sys.get_state(pid)

    assert_receive {:stream, nil, "message", %{method: "notifications/progress"}}
    assert before.timer != state.timer
    assert Process.read_timer(before.timer) == false
    assert is_integer(Process.read_timer(state.timer))
    refute_receive {:stream, nil, "closed", _}, 0
  end

  test "a timeout queued before activity cannot close the refreshed stream", ctx do
    pid = start_session(ctx)
    before = :sys.get_state(pid)
    Process.cancel_timer(before.timer)

    Session.notify(pid, %{message: "activity"})
    send(pid, {:timeout, before.timer, :inactivity})
    state = :sys.get_state(pid)

    assert_receive {:stream, nil, "message", %{message: "activity"}}
    assert state.timer != before.timer
    assert is_integer(Process.read_timer(state.timer))
    refute_receive {:stream, nil, "closed", _}, 0
  end

  test "untagged inactivity and unrelated messages do not close or refresh the stream", ctx do
    pid = start_session(ctx)
    before = :sys.get_state(pid)
    send(pid, :inactivity)
    send(pid, :unrelated)

    assert :sys.get_state(pid).timer == before.timer
    refute_receive {:stream, nil, "closed", _}, 0
  end

  test "finishing a stream cancels its outstanding timer", ctx do
    pid = start_session(ctx)
    state = :sys.get_state(pid)
    monitor = Process.monitor(pid)

    Session.finish(pid)

    assert_receive {:DOWN, ^monitor, :process, ^pid, {:shutdown, :closed}}
    assert Process.read_timer(state.timer) == false
  end

  test "a genuinely expired timer closes an inactive request", ctx do
    start_session(ctx, timeout: to_timeout(millisecond: 0))
    assert_receive {:stream, nil, "closed", "inactivity"}
  end

  test "infinity never creates a timer, including after progress", ctx do
    pid = start_session(ctx, timeout: :infinity)
    assert :sys.get_state(pid).timer == nil

    Session.notify_progress(pid, "token", 1)
    send(pid, {:timeout, make_ref(), :inactivity})
    send(pid, :inactivity)

    assert :sys.get_state(pid).timer == nil
    assert_receive {:stream, nil, "message", %{method: "notifications/progress"}}
    refute_receive {:stream, nil, "closed", _}, 0
  end

  test "persistent legacy streams send a ping and rearm on inactivity", ctx do
    pid = start_session(ctx, close_after_complete: false)
    before = :sys.get_state(pid)
    Process.cancel_timer(before.timer)
    send(pid, {:timeout, before.timer, :inactivity})
    state = :sys.get_state(pid)

    assert_receive {:stream, nil, "message", %{method: "ping"}}
    assert state.timer != before.timer
    assert is_integer(Process.read_timer(state.timer))
    refute_receive {:stream, nil, "closed", _}, 0
  end

  test "persistent stateless streams send a comment and rearm on inactivity", ctx do
    request = %Request{id: 1, meta: %{"protocolVersion" => "2026-07-28"}}
    pid = start_session(ctx, close_after_complete: false, request: request)
    before = :sys.get_state(pid)
    Process.cancel_timer(before.timer)
    send(pid, {:timeout, before.timer, :inactivity})
    state = :sys.get_state(pid)

    assert_receive {:stream, nil, "comment", nil}
    assert state.timer != before.timer
    assert is_integer(Process.read_timer(state.timer))
    refute_receive {:stream, nil, "closed", _}, 0
  end
end

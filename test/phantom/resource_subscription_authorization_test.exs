defmodule Phantom.ResourceSubscriptionAuthorizationTest.Router do
  use Phantom.Router, name: "Resource subscription authorization test"

  require Phantom.Resource, as: Resource

  resource "authz:///records/:id", :record

  def connect(session, %Plug.Conn{} = conn) do
    user_id = conn |> Plug.Conn.get_req_header("x-user-id") |> List.first()
    return = conn |> Plug.Conn.get_req_header("x-authz-return") |> List.first()
    {:ok, Phantom.Session.assign(session, user_id: user_id, authz_return: return)}
  end

  def connect(session, _context), do: {:ok, session}

  def authorize_resource_subscriptions(resources, session) do
    if listener = Process.whereis(Phantom.ResourceSubscriptionAuthorizationTest.Listener) do
      send(listener, {:authorization_batch, resources, session})
    end

    case :persistent_term.get({__MODULE__, session.assigns[:user_id]}, :all) do
      :raise ->
        raise "authorization failed"

      :invalid ->
        %{allowed: resources}

      nil ->
        nil

      allowed_ids ->
        allowed =
          Enum.filter(resources, fn {_uri, %{"id" => id}, _template} ->
            allowed_ids == :all or id in allowed_ids
          end)

        if session.assigns[:authz_return] == "uris" do
          Enum.map(allowed, &elem(&1, 0))
        else
          allowed
        end
    end
  end

  def record(params, session), do: {:reply, Resource.text(inspect(params)), session}
end

defmodule Phantom.ResourceSubscriptionAuthorizationTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  import Phantom.TestDispatcher
  import Plug.Conn

  alias Phantom.ResourceSubscriptionAuthorizationTest.Router
  alias Phantom.Session

  @listener Phantom.ResourceSubscriptionAuthorizationTest.Listener

  setup do
    Process.register(self(), @listener)
    start_supervised({Phoenix.PubSub, name: Test.PubSub})
    start_supervised({Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Test.PubSub]})
    Phantom.Cache.register(Router)

    on_exit(fn ->
      Enum.each([nil, "alice", "bob"], &:persistent_term.erase({Router, &1}))
    end)

    :ok
  end

  test "resolves, deduplicates, and authorizes resources as tuples or URI strings" do
    first = "authz:///records/first"
    second = "authz:///records/second"
    session = Session.new("session", router: Router) |> Session.assign(user_id: nil)

    resolved =
      Phantom.Router.resolve_resources(Router, session, [
        first,
        second,
        first,
        "authz:///unknown/record",
        "not a uri"
      ])

    assert [
             {^first, %{"id" => "first"}, %Phantom.ResourceTemplate{}},
             {^second, %{"id" => "second"}, %Phantom.ResourceTemplate{}}
           ] = resolved

    assert Phantom.Router.authorize_resource_subscriptions(Router, resolved, session) == resolved

    uri_session = Session.assign(session, :authz_return, "uris")

    assert Phantom.Router.authorize_resource_subscriptions(Router, resolved, uri_session) ==
             resolved

    flush_authorization_batches()
    assert Phantom.Router.authorize_resource_subscriptions(Router, [], session) == []
    refute_receive {:authorization_batch, _, _}
  end

  test "invalid callback results and exceptions fail closed" do
    uri = "authz:///records/first"
    session = Session.new("session", router: Router) |> Session.assign(user_id: nil)
    resolved = Phantom.Router.resolve_resources(Router, session, [uri])

    :persistent_term.put({Router, nil}, :invalid)
    assert Phantom.Router.authorize_resource_subscriptions(Router, resolved, session) == []

    :persistent_term.put({Router, nil}, nil)
    assert Phantom.Router.authorize_resource_subscriptions(Router, resolved, session) == []

    :persistent_term.put({Router, nil}, :raise)

    assert capture_log(fn ->
             assert Phantom.Router.authorize_resource_subscriptions(Router, resolved, session) ==
                      []
           end) =~ "authorization failed closed"
  end

  test "subscribe authorization and bulk update authorization use the same callback", context do
    session_id = to_string(context.test)
    alice_one = "authz:///records/alice-1"
    alice_two = "authz:///records/alice-2"
    bob = "authz:///records/bob-1"

    :persistent_term.put({Router, "alice"}, ["alice-1", "alice-2"])

    request_sse_stream(authz_opts(session_id, "alice"))
    assert_sse_connected()

    request_resource_subscribe(bob, authz_opts(session_id, "alice", id: 2))
    assert_connected(_conn)
    assert_response(2, denied)
    assert denied.error.code == -32_002

    request_resource_subscribe(alice_one, authz_opts(session_id, "alice", id: 3))
    assert_connected(_conn)
    assert_response(3, %{result: %{}})

    request_resource_subscribe(alice_two, authz_opts(session_id, "alice", id: 4))
    assert_connected(_conn)
    assert_response(4, %{result: %{}})

    wait_for_subscriptions([alice_one, alice_two])
    flush_authorization_batches()

    # Simulate permission revocation after both subscriptions were accepted.
    :persistent_term.put({Router, "alice"}, ["alice-1"])

    assert {:ok, 1} =
             Phantom.Tracker.notify_resources_updated([
               alice_one,
               alice_two,
               alice_one,
               "authz:///records/not-subscribed"
             ])

    assert_receive {:authorization_batch, resources, %Session{assigns: %{user_id: "alice"}}}
    assert MapSet.new(Enum.map(resources, &elem(&1, 0))) == MapSet.new([alice_one, alice_two])

    assert_notify(%{
      method: "notifications/resources/updated",
      params: %{uri: ^alice_one}
    })

    refute_receive {:response, nil, "message",
                    %{method: "notifications/resources/updated", params: %{uri: ^alice_two}}}
  end

  defp authz_opts(session_id, user_id, extra \\ []) do
    before_call = fn conn ->
      conn
      |> put_req_header("x-user-id", user_id)
      |> put_req_header("x-authz-return", "uris")
    end

    Keyword.merge(
      [session_id: session_id, router: Router, before_call: before_call],
      extra
    )
  end

  defp wait_for_subscriptions(expected, attempts \\ 50)

  defp wait_for_subscriptions(expected, attempts) when attempts > 0 do
    actual =
      Phantom.Tracker.list_resource_listeners()
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    if MapSet.subset?(MapSet.new(expected), actual) do
      :ok
    else
      Process.sleep(10)
      wait_for_subscriptions(expected, attempts - 1)
    end
  end

  defp wait_for_subscriptions(expected, 0) do
    flunk("subscriptions were not tracked: #{inspect(expected)}")
  end

  defp flush_authorization_batches do
    receive do
      {:authorization_batch, _, _} -> flush_authorization_batches()
    after
      0 -> :ok
    end
  end
end

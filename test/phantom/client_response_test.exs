defmodule Phantom.ClientResponseTest do
  use ExUnit.Case, async: true

  @pubsub Phantom.ClientResponseTest.PubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    :ok
  end

  # No `Phantom.Tracker` runs here, so delivery cannot depend on its replication.
  test "routes a client response to the waiting process through PubSub" do
    Phantom.Tracker.subscribe_client_response(@pubsub, "elicit-1")

    Phantom.Router.route_client_response(@pubsub, "elicit-1", %{"action" => "accept"})
    assert_receive {:phantom_client_response, "elicit-1", %{"action" => "accept"}}

    Phantom.Router.route_client_response(@pubsub, "elicit-1", {:error, %{"code" => -1}})
    assert_receive {:phantom_client_response, "elicit-1", {:error, %{"code" => -1}}}
  end

  test "does not deliver a response for another request" do
    Phantom.Tracker.subscribe_client_response(@pubsub, "elicit-1")
    Phantom.Router.route_client_response(@pubsub, "elicit-2", %{"action" => "accept"})
    refute_receive {:phantom_client_response, _, _}
  end
end

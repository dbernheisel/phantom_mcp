defmodule Phantom.A2A.DistributedTest do
  use Phantom.Test.NodeCase

  alias Phantom.A2A.{Task, TaskRef}

  @node1 :"node1@127.0.0.1"
  @node2 :"node2@127.0.0.1"
  @port 4140

  # `:rpc.block_call` runs in the peer's long-lived rex process, so what it
  # links to keeps running. Both nodes store push configs; node1 serves the agent.
  setup_all do
    {:ok, _} = :rpc.block_call(@node2, Phantom.ACTS.Store, :start_link, [[]])

    {:ok, _} =
      :rpc.block_call(@node1, Supervisor, :start_link, [
        [
          Phantom.ACTS.Store,
          {Bandit,
           plug: {Phantom.ACTS.HTTP, pubsub: Phantom.Test.PubSub},
           ip: {127, 0, 0, 1},
           port: @port,
           startup_log: false}
        ],
        [strategy: :one_for_one]
      ])

    :ok
  end

  defp rpc(method, params, opts \\ []) do
    Req.post!("http://127.0.0.1:#{@port}/a2a/acts",
      json: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
      headers: [{"a2a-version", "1.0"}] ++ Keyword.get(opts, :headers, []),
      into: Keyword.get(opts, :into),
      receive_timeout: @timeout
    )
  end

  test "an event published on one node reaches a stream on another" do
    %{body: %{"result" => %{"task" => %{"id" => task_id, "contextId" => context_id}}}} =
      rpc("SendMessage", %{
        "message" => %{
          "messageId" => "m1",
          "role" => "ROLE_USER",
          "parts" => [%{"text" => "tck-cancel"}]
        },
        "configuration" => %{"returnImmediately" => true}
      })

    stream =
      rpc("SubscribeToTask", %{"id" => task_id},
        headers: [{"accept", "text/event-stream"}],
        into: :self
      )

    # The current task comes first, so the stream is subscribed.
    assert poll_for_sse_event(stream, @timeout, &match?(%{"result" => %{"task" => _}}, &1))

    ref = %TaskRef{
      pubsub: Phantom.Test.PubSub,
      router: Phantom.ACTS.Router,
      agent_id: "acts",
      task_id: task_id,
      context_id: context_id
    }

    :ok =
      :rpc.call(@node2, Phantom.A2A, :publish, [ref, Task.status(:completed, "Done on node2")])

    assert %{
             "result" => %{
               "statusUpdate" => %{
                 "taskId" => ^task_id,
                 "contextId" => ^context_id,
                 "status" => %{"state" => "TASK_STATE_COMPLETED"}
               }
             }
           } =
             poll_for_sse_event(
               stream,
               @timeout,
               &match?(%{"result" => %{"statusUpdate" => _}}, &1)
             )
  end
end

defmodule Phantom.A2A do
  @moduledoc """
  Serve [A2A](https://a2a-protocol.org) agents from a `Phantom.Router`.

  Declare agents in the router, and implement each with `Phantom.A2A.Agent`:

      defmodule MyApp.MCP.Router do
        use Phantom.Router, name: "MyApp", a2a: [well_known: "research"]

        agent "research", MyApp.Agents.Research
      end

  Then serve them with `Phantom.A2A.Plug`:

      get "/.well-known/agent-card.json", Phantom.A2A.Plug, router: MyApp.MCP.Router

      scope "/a2a" do
        forward "/", Phantom.A2A.Plug, router: MyApp.MCP.Router, pubsub: MyApp.PubSub
      end
  """

  alias Phantom.A2A.{ArtifactUpdate, Message, StatusUpdate, Task, TaskRef}

  @type event :: Task.t() | StatusUpdate.t() | ArtifactUpdate.t() | Message.t()

  @doc """
  Send an event about a task to the clients waiting on it, on any node.

  Save the change first: Phantom doesn't store it, and a client that asks
  for the task next gets it from `c:Phantom.A2A.Agent.get_task/2`.
  Without a `:pubsub` on `Phantom.A2A.Plug`, nothing is sent.
  """
  @spec publish(TaskRef.t(), event()) :: :ok
  def publish(%TaskRef{pubsub: nil}, _event), do: :ok

  def publish(%TaskRef{} = ref, event) do
    Phoenix.PubSub.broadcast(ref.pubsub, topic(ref), {:phantom_a2a_event, event})
  end

  @doc false
  def subscribe(%TaskRef{pubsub: nil}), do: :ok
  def subscribe(%TaskRef{} = ref), do: Phoenix.PubSub.subscribe(ref.pubsub, topic(ref))

  @doc false
  def unsubscribe(%TaskRef{pubsub: nil}), do: :ok
  def unsubscribe(%TaskRef{} = ref), do: Phoenix.PubSub.unsubscribe(ref.pubsub, topic(ref))

  defp topic(ref), do: "phantom:a2a:#{inspect(ref.router)}:#{ref.agent_id}:#{ref.task_id}"

  @doc "An unguessable ID for a task or context"
  def generate_id, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc false
  def event_to_json(%Task{} = task), do: %{"task" => Task.to_json(task)}
  def event_to_json(%Message{} = message), do: %{"message" => Message.to_json(message)}

  def event_to_json(%StatusUpdate{} = update),
    do: %{"statusUpdate" => StatusUpdate.to_json(update)}

  def event_to_json(%ArtifactUpdate{} = update),
    do: %{"artifactUpdate" => ArtifactUpdate.to_json(update)}
end

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
  Send an event about a task to the clients waiting on it, on any node, and
  push it to the task's webhooks when its agent supports push notifications.

  Save the change first, with `Phantom.A2A.Events.apply/2`, and publish the
  event it returns. Phantom doesn't store events, and a client that asks for
  the task next gets it from `c:Phantom.A2A.Agent.get_task/2`. The event's
  number lets a stream skip what that task already includes. Phantom fills in
  the event's task and context IDs from the ref. Without a `:pubsub`
  on `Phantom.A2A.Plug`, nothing is streamed.
  """
  def publish(%TaskRef{} = ref, event) do
    event = fill_ids(event, ref)

    if ref.pubsub,
      do:
        Phoenix.PubSub.broadcast(ref.pubsub, topic(ref), {:phantom_a2a_event, ref.task_id, event})

    push(ref, event)
  end

  defp fill_ids(%struct{} = event, ref) when struct in [StatusUpdate, ArtifactUpdate],
    do: %{
      event
      | task_id: event.task_id || ref.task_id,
        context_id: event.context_id || ref.context_id
    }

  defp fill_ids(event, _ref), do: event

  defp push(ref, event) do
    with {:ok, %{handler: handler}, _params} <-
           Phantom.Router.A2A.match(ref.router, String.split(ref.agent_id, "/")),
         true <- handler.__phantom_a2a__(:push_notifications) do
      Enum.each(handler.push_configs(ref), &handler.deliver_push(&1, event, ref))
    end

    :ok
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
  def event_from_json(%{"task" => json}), do: Task.from_json(json)
  def event_from_json(%{"message" => json}), do: Message.from_json(json)
  def event_from_json(%{"statusUpdate" => json}), do: StatusUpdate.from_json(json)
  def event_from_json(%{"artifactUpdate" => json}), do: ArtifactUpdate.from_json(json)
  def event_from_json(_json), do: {:error, "unknown event"}

  @doc false
  def event_to_json(event, opts \\ [])
  def event_to_json(%Task{} = task, opts), do: %{"task" => Task.to_json(task, opts)}
  def event_to_json(%Message{} = message, _opts), do: %{"message" => Message.to_json(message)}

  def event_to_json(%StatusUpdate{} = update, _opts),
    do: %{"statusUpdate" => StatusUpdate.to_json(update)}

  def event_to_json(%ArtifactUpdate{} = update, _opts),
    do: %{"artifactUpdate" => ArtifactUpdate.to_json(update)}
end

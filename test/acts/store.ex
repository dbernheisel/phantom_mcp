defmodule Phantom.ACTS.Store do
  @moduledoc """
  Tasks and push notification configs of the ACTS agent, in memory. Every
  change is saved here before it is published, so a `GetTask` after an event
  sees it.
  """

  use Agent

  alias Phantom.A2A.{Events, PushConfig, Task}

  def start_link(_opts),
    do: Agent.start_link(fn -> %{tasks: %{}, configs: %{}} end, name: __MODULE__)

  def get(task_id), do: Agent.get(__MODULE__, &Map.fetch(&1.tasks, task_id))
  def all, do: Agent.get(__MODULE__, &Map.values(&1.tasks))
  def put(%Task{} = task), do: Agent.update(__MODULE__, &put_in(&1, [:tasks, task.id], task))

  @doc "Apply an event to a stored task, then publish it."
  def emit(%Phantom.A2A.TaskRef{task_id: task_id} = ref, event) do
    event =
      Agent.get_and_update(__MODULE__, fn state ->
        {:ok, task, event} = Events.apply(Map.fetch!(state.tasks, task_id), event)
        {event, put_in(state, [:tasks, task_id], task)}
      end)

    Phantom.A2A.publish(ref, event)
  end

  def configs(task_id), do: Agent.get(__MODULE__, &Map.get(&1.configs, task_id, %{}))

  def put_config(%PushConfig{} = config) do
    Agent.update(__MODULE__, fn state ->
      configs = state.configs |> Map.get(config.task_id, %{}) |> Map.put(config.id, config)
      put_in(state, [:configs, config.task_id], configs)
    end)
  end

  def delete_config(task_id, id) do
    Agent.update(__MODULE__, fn state ->
      update_in(
        state,
        [:configs],
        &Map.update(&1, task_id, %{}, fn configs -> Map.delete(configs, id) end)
      )
    end)
  end
end

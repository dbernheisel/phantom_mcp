defmodule Phantom.ACTS.Store do
  @moduledoc """
  Tasks of the ACTS agent, in memory. Every change is saved here before it is
  published, so a `GetTask` after an event sees it.
  """

  use Agent

  alias Phantom.A2A.{Events, Task}

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def get(task_id), do: Agent.get(__MODULE__, &Map.fetch(&1, task_id))
  def all, do: Agent.get(__MODULE__, &Map.values/1)
  def put(%Task{} = task), do: Agent.update(__MODULE__, &Map.put(&1, task.id, task))

  @doc "Apply an event to a stored task, then publish it."
  def emit(%Phantom.A2A.TaskRef{task_id: task_id} = ref, event) do
    Agent.update(__MODULE__, fn tasks ->
      {:ok, task} = Events.apply(Map.fetch!(tasks, task_id), event)
      Map.put(tasks, task_id, task)
    end)

    Phantom.A2A.publish(ref, event)
  end
end

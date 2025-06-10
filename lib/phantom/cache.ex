defmodule Phantom.Cache do
  @moduledoc false

  def register(module) do
    case Code.ensure_compiled(module) do
      {:module, module} ->
        info = module.__phantom__(:info)
        resource_templates = Map.get(info, :resource_templates, [])

        :persistent_term.put({Phantom, module, :initialized}, true)
        :persistent_term.put({Phantom, module, :tools}, Map.get(info, :tools, []))
        :persistent_term.put({Phantom, module, :prompts}, Map.get(info, :prompts, []))
        :persistent_term.put({Phantom, module, :resource_templates}, resource_templates)

        info

      _ ->
        {:error, :router_not_found}
    end
  end

  def get(session, module, type) do
    available = :persistent_term.get({Phantom, module, type}, [])

    case Map.get(session, type) do
      nil -> available
      authorized -> Enum.filter(available, &(&1.name in authorized))
    end
  end

  def initialized?(router) do
    :persistent_term.get({__MODULE__, router, :initialized}, false) == true
  end
end

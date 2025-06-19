defmodule Phantom.Cache do
  @moduledoc false

  def register(router) do
    if not :persistent_term.get({Phantom, router, :initialized}, false) do
      info = router.__phantom__(:info)
      compiled_resource_templates = Map.get(info, :resource_templates, [])
      compiled_prompts = Map.get(info, :prompts, [])
      compiled_tools = Map.get(info, :tools, [])

      :persistent_term.put({Phantom, router, :tools}, compiled_tools)
      :persistent_term.put({Phantom, router, :prompts}, compiled_prompts)
      :persistent_term.put({Phantom, router, :resource_templates}, compiled_resource_templates)
      :persistent_term.put({Phantom, router, :initialized}, true)
    end

    :ok
  end

  def add_tool(router, tool_spec) do
    tool = Phantom.Tool.build(tool_spec)
    existing = :persistent_term.get({Phantom, router, :tools}, [])
    tools = [tool | existing]
    validate!([tool])
    raise_if_duplicates(tools)
    :persistent_term.put({Phantom, router, :tools}, tools)
  end

  def add_prompt(router, prompt_spec) do
    prompt = Phantom.Prompt.build(prompt_spec)
    existing = :persistent_term.get({Phantom, router, :prompts}, [])
    prompts = [prompt | existing]
    validate!([prompt])
    raise_if_duplicates(prompts)
    :persistent_term.put({Phantom, router, :prompts}, prompts)
  end

  defmacro add_resource_template(router, resource_template_spec) do
    resource_template = Phantom.ResourceTemplate.build(resource_template_spec)
    existing = :persistent_term.get({Phantom, router, :resource_templates}, [])
    resource_templates = [resource_template | existing]
    validate!([resource_template])
    raise_if_duplicates(resource_templates)
    :persistent_term.put({Phantom, router, :resource_templates}, resource_templates)
    require Phantom.Router
    Phantom.Router.__create_resource_routers__(resource_templates, __CALLER__)
  end

  def get(session, module, type) do
    available = :persistent_term.get({Phantom, module, type}, [])

    case Map.get(session, :"allowed_#{type}") do
      nil -> available
      authorized -> Enum.filter(available, &(&1.name in authorized))
    end
  end

  def initialized?(router) do
    :persistent_term.get({__MODULE__, router, :initialized}, false) == true
  end

  @doc false
  def validate!(entities) do
    Enum.each(entities, fn %mod{handler: handler, function: function} = entity ->
      Code.ensure_loaded!(handler)

      if not function_exported?(handler, function, 2) do
        func = mod |> to_string() |> String.split(".") |> List.last() |> Macro.underscore()
        file = Path.relative_to_cwd(entity.meta.file)

        raise "#{func} was defined in #{file}:#{entity.meta.line} to call #{inspect(handler)}.#{function}/3 but that module and function does not exist."
      end
    end)
  end

  @doc false
  def raise_if_duplicates([]), do: :ok

  def raise_if_duplicates([%Phantom.ResourceTemplate{} | _] = resource_templates) do
    resource_templates
    |> Enum.group_by(&{&1.router, &1.name})
    |> Enum.each(fn
      {{_router, _name}, [_template]} ->
        :ok

      {{router, name}, templates} ->
        raise """
        There are conflicting resources with the name #{inspect(name)}.
        Please distinguish them by providing a `:name` option.

        #{inspect(Enum.map(templates, &{router, &1.handler, &1.function}), pretty: true)}
        """
    end)

    :ok
  end

  def raise_if_duplicates([%mod{} | _] = tools_or_prompts) do
    tools_or_prompts
    |> Enum.group_by(& &1.name)
    |> Enum.each(fn
      {_name, [_entity]} ->
        :ok

      {name, tools_or_prompts} ->
        entity = mod |> to_string() |> String.split(".") |> List.last() |> Macro.underscore()

        raise """
        There are conflicting #{entity}s with the name #{inspect(name)}.
        Please distinguish them by providing a `:name` option.

        #{inspect(Enum.map(tools_or_prompts, &{&1.handler, &1.function}), pretty: true)}
        """
    end)
  end
end

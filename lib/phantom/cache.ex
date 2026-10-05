defmodule Phantom.Cache do
  @moduledoc """
  Storage for tooling specifications. The backend is `:persistent_term`.

  You typically won't need to interact with `Phantom.Cache` directly, but
  if you're registering new tooling within the runtime, then you may want
  to use the functions herein.
  """

  require Logger

  @doc """
  Initialize the cache with compiled tooling for the given router.

  You likely don't need to call this yourself, as `Phantom.Plug` will call it if needed.
  """
  def register(router) do
    if not :persistent_term.get({Phantom, router, :initialized}, false) do
      info = router.__phantom__(:info)

      compiled_resource_templates =
        info |> Map.get(:resource_templates, []) |> Enum.sort_by(& &1.name)

      compiled_prompts = info |> Map.get(:prompts, []) |> Enum.sort_by(& &1.name)
      compiled_tools = info |> Map.get(:tools, []) |> Enum.sort_by(& &1.name)

      :persistent_term.put({Phantom, router, :tools}, compiled_tools)
      :persistent_term.put({Phantom, router, :prompts}, compiled_prompts)
      :persistent_term.put({Phantom, router, :resource_templates}, compiled_resource_templates)
      :persistent_term.put({Phantom, router, :initialized}, true)
    end

    :ok
  end

  @doc "Add an MCP Tool for the given router."
  def add_tool(router, tool_spec) do
    tools = tool_spec |> List.wrap() |> Enum.map(&Phantom.Tool.build/1)
    existing = :persistent_term.get({Phantom, router, :tools}, [])
    tools = Enum.sort_by(Enum.uniq(tools ++ existing), & &1.name)
    validate!(tools)
    raise_if_duplicates(tools)
    Phantom.Tracker.notify_tool_list()
    :persistent_term.put({Phantom, router, :tools}, tools)
  end

  @doc "Add an MCP Prompt for the given router."
  def add_prompt(router, prompt_spec) do
    prompts = prompt_spec |> List.wrap() |> Enum.map(&Phantom.Prompt.build/1)
    existing = :persistent_term.get({Phantom, router, :prompts}, [])
    prompts = Enum.sort_by(Enum.uniq(prompts ++ existing), & &1.name)
    validate!(prompts)
    raise_if_duplicates(prompts)
    Phantom.Tracker.notify_prompt_list()
    :persistent_term.put({Phantom, router, :prompts}, prompts)
  end

  @doc """
  Add an MCP Resource Template for the given router.

  This will also purge and generate a ResourceRouter module for each scheme
  provided.
  """
  defmacro add_resource_template(router, resource_template_spec) do
    resource_templates =
      resource_template_spec |> List.wrap() |> Enum.map(&Phantom.ResourceTemplate.build/1)

    with_lock(router, fn ->
      existing = :persistent_term.get({Phantom, router, :resource_templates}, [])

      resource_templates =
        Enum.sort_by(Enum.uniq(resource_templates ++ existing), &{&1.scheme, &1.name})

      validate!(resource_templates)
      raise_if_duplicates(resource_templates)
      :persistent_term.put({Phantom, router, :resource_templates}, resource_templates)
      Phantom.Router.__create_resource_routers__(resource_templates, __CALLER__)
    end)
  end

  @doc """
  Add one skill, or a list of skills, for the given router. Each takes the same
  arguments as `Phantom.Router.skill/3`:

      Phantom.Cache.add_skill(MyApp.MCP.Router,
        path: "acme/billing/refunds",
        handler: MyApp.MCP.Skills,
        function: :refunds
      )

  This regenerates the router's skill routes once for each call.
  """
  def add_skill(router, skill_specs) do
    skill_specs =
      if is_map(skill_specs) or Keyword.keyword?(skill_specs),
        do: [skill_specs],
        else: skill_specs

    skills =
      Enum.map(skill_specs, fn spec ->
        spec |> Map.new() |> Map.put(:router, router) |> Phantom.Router.skill_template()
      end)

    validate!(skills)
    register(router)

    with_lock(router, fn ->
      existing = :persistent_term.get({Phantom, router, :resource_templates}, [])
      resource_templates = Enum.sort_by(Enum.uniq(skills ++ existing), & &1.name)
      raise_if_duplicates(resource_templates)

      __redefine_modules__(fn ->
        resource_templates
        |> Enum.filter(&(&1.scheme == "skill"))
        |> Phantom.Router.__create_resource_routers__(__ENV__)
      end)

      :persistent_term.put({Phantom, router, :resource_templates}, resource_templates)
    end)

    :ok
  end

  # The lock is local, because :persistent_term and the generated routers are local to each node.
  defp with_lock(router, fun), do: :global.trans({{__MODULE__, router}, self()}, fun, [node()])

  @doc false
  def __redefine_modules__(fun) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, fun.()}
        rescue
          exception -> {:error, exception, __STACKTRACE__}
        end
      end)

    for %{message: message, severity: severity} = diagnostic <- diagnostics,
        not String.starts_with?(message, "redefining module") do
      Logger.log(
        if(severity == :error, do: :error, else: :warning),
        Exception.format_file_line(
          Path.relative_to_cwd(diagnostic.file || "nofile"),
          line(diagnostic)
        ) <>
          " " <> message
      )
    end

    case result do
      {:ok, value} -> value
      {:error, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  defp line(%{position: {line, _column}}), do: line
  defp line(%{position: line}), do: line

  @doc """
  List all the entities for the given type.
  """
  @spec list(Phantom.Session.t() | nil, module(), :tools | :prompts | :resource_templates) ::
          list(Phantom.Tool.t() | Phantom.Prompt.t() | Phantom.ResourceTemplate.t())
  def list(nil, module, type) do
    :persistent_term.get({Phantom, module, type}, [])
  end

  def list(session, module, type) do
    available = :persistent_term.get({Phantom, module, type}, [])

    case Map.get(session, :"allowed_#{type}") do
      nil -> available
      authorized -> Enum.filter(available, &(&1.name in authorized))
    end
  end

  @doc false
  def initialized?(router) do
    :persistent_term.get({Phantom, router, :initialized}, false) == true
  end

  @doc false
  def validate!(entities) do
    Enum.each(entities, fn %mod{handler: handler, function: function} = entity ->
      Code.ensure_loaded!(handler)

      if not function_exported?(handler, function, 2) do
        func = mod |> to_string() |> String.split(".") |> List.last() |> Macro.underscore()
        file = Path.relative_to_cwd(entity.meta.file)

        raise "#{func} was defined in #{file}:#{entity.meta.line} to call #{inspect(handler)}.#{function}/2 but that module and function does not exist."
      end
    end)
  end

  @doc false
  def raise_if_duplicates([]), do: :ok

  def raise_if_duplicates([%mod{} | _] = entities) do
    entities
    |> Enum.group_by(& &1.name)
    |> Enum.each(fn
      {_name, [_entity]} ->
        :ok

      {name, entities} ->
        entity = mod |> to_string() |> String.split(".") |> List.last() |> Macro.underscore()

        raise """
        There are conflicting #{entity}s with the name #{inspect(name)}.
        Please distinguish them by providing a `:name` option.

        #{inspect(Enum.map(entities, &{&1.handler, &1.function}), pretty: true)}
        """
    end)
  end
end

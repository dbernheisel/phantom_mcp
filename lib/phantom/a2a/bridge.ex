defmodule Phantom.A2A.Bridge do
  @moduledoc """
  Serve a router's MCP tools as an A2A agent.

      agent "tools", Phantom.A2A.Bridge, tools: ~w[search_studies create_question]

  The agent's card lists each tool as a skill, and an extension with the
  tools' input schemas:

      https://github.com/dbernheisel/phantom_mcp/a2a/extensions/mcp-tools/v1

  A client calls a tool with a message whose data part names it:

      {"data": {"tool": "search_studies", "arguments": {"query": "churn"}}}

  The tool runs with `Phantom.Router.call_tool/4`, with the session's
  assigns and allow-list, and its arguments are validated as for `tools/call`.
  The agent answers with a message of the tool's result: text as text parts,
  structured content as a data part, images and audio as bytes, and resource
  links as URLs. A tool error sets `"mcp/isError": true` in the message's
  metadata.

  A message that names no tool goes to the `:fallback` agent, or gets a reply
  that lists the tools. Tasks the fallback answers with are fetched, canceled,
  and continued through it.

  The card is public and has no session, so it lists every tool `:tools` allows,
  whatever `Phantom.Session.allow_tools/2` would later permit. Set `:tools` to
  what the public may see.

  ## Options

    * `:tools` - the names of the tools to serve (default: every tool)
    * `:name`, `:description` - for the card (default: the router's name and
      instructions)
    * `:fallback` - a `Phantom.A2A.Agent` for messages that name no tool

  ## Long-running tools

  When the router implements `c:Phantom.Router.get_task/2`, the bridge calls
  tools with the MCP Tasks extension, so a tool may answer with a
  `Phantom.Tasks`. The client gets an A2A task with the same ID, in a context
  of its own. MCP tasks can't keep a client's context, so a tool call that names
  a `contextId` is refused on such a router:

    * the task's status, `status_message`, and `error` become the A2A status
      and its message, and a completed `result` becomes a `"result"` artifact;
    * `input_requests` become an `input_required` status whose message has a
      data part `{"inputRequests": ...}`. The client answers with a message on
      the task with a data part `{"inputResponses": {key: response}}`, which
      goes to `c:Phantom.Router.update_task/3`;
    * `GetTask` and `CancelTask` go to `c:Phantom.Router.get_task/2` and
      `c:Phantom.Router.cancel_task/2`;
    * after each `Phantom.Tracker.notify_task_updated/1` for the task, a
      waiting `SendMessage` or a stream gets the task again. This needs
      `Phantom.Tracker` in your supervision tree.

  Tools that answer from another process (`{:noreply, session}`) block the
  request until they respond. A tool that elicits without a task gets
  `:not_supported`, as there is no MCP client to ask.
  """

  use Phantom.A2A.Agent,
    name: "MCP tools",
    description: "Calls MCP tools",
    input_modes: ~w[application/json text/plain],
    output_modes: ~w[application/json text/plain]

  require Logger

  alias Phantom.A2A.{AgentSkill, Artifact, Error, Message, Part, Task, TaskStatus}

  @extension "https://github.com/dbernheisel/phantom_mcp/a2a/extensions/mcp-tools/v1"

  @doc "The URI of the extension that lists the tools' schemas"
  def extension, do: @extension

  @impl Phantom.A2A.Agent
  def card(card, %{router: router, opts: opts}) do
    info = router.__phantom__(:info)
    tools = tools(router, nil, opts)
    instructions = if info.instructions in [nil, ""], do: nil, else: info.instructions

    %{
      card
      | name: opts[:name] || info.name,
        description: String.trim(opts[:description] || instructions || "Tools of #{info.name}"),
        version: info.version,
        skills: Enum.map(tools, &to_skill/1),
        extensions: [
          %{
            uri: @extension,
            description: ~s(Call a tool with a data part: {"tool": name, "arguments": {...}}),
            params: %{"tools" => Enum.map(tools, &tool_json/1)}
          }
        ]
    }
  end

  @impl Phantom.A2A.Agent
  def handle_message(%Message{task_id: task_id} = message, ctx) when is_binary(task_id) do
    case {mcp_task(task_id, ctx), ctx.agent.opts[:fallback]} do
      {:error, fallback} when not is_nil(fallback) -> fallback.handle_message(message, ctx)
      _mcp_task -> continue_task(task_id, message, ctx)
    end
  end

  def handle_message(message, ctx) do
    case tool_call(message) do
      {name, arguments} -> call(name, arguments, ctx)
      nil -> no_tool(message, ctx)
    end
  end

  defp tool_call(%Message{parts: parts}) do
    Enum.find_value(parts, fn
      %Part{data: %{"tool" => name} = data} when is_binary(name) ->
        {name, data["arguments"] || %{}}

      _part ->
        nil
    end)
  end

  defp call(_name, arguments, ctx) when not is_map(arguments),
    do: {:error, Error.invalid_params("arguments must be an object"), ctx}

  defp call(name, arguments, ctx) do
    router = ctx.session.router
    tasks? = Phantom.Router.tasks_enabled?(router)

    cond do
      not Enum.any?(tools(router, ctx.session, ctx.agent.opts), &(&1.name == name)) ->
        {:error, Error.invalid_params("Unknown tool: #{name}"), ctx}

      tasks? and is_binary(ctx.requested_context_id) ->
        {:error, Error.invalid_params("This agent can't use a contextId from the client"), ctx}

      true ->
        run_tool(name, arguments, tasks?, ctx)
    end
  end

  defp run_tool(name, arguments, tasks?, ctx) do
    case Phantom.Router.call_tool(ctx.session, name, arguments, tasks: tasks?) do
      {:ok, %Phantom.Tasks{} = task} ->
        {:reply, to_a2a(task), ctx}

      {:ok, result} ->
        {:reply, reply(result), ctx}

      {:error, :timeout} ->
        {:error, %Error{code: -32603, message: "Tool #{name} timed out"}, ctx}

      {:error, error} ->
        {:error, error(error), ctx}
    end
  end

  ## MCP tasks

  @impl Phantom.A2A.Agent
  def follows_mcp_tasks?, do: true

  @impl Phantom.A2A.Agent
  def get_task(task_id, ctx) do
    case mcp_task(task_id, ctx) do
      {:ok, task} -> {:ok, to_a2a(task)}
      :error -> fallback_task(task_id, ctx)
    end
  end

  defp fallback_task(task_id, ctx) do
    case ctx.agent.opts[:fallback] do
      nil -> {:error, :not_found}
      fallback -> fallback.get_task(task_id, ctx)
    end
  end

  @impl Phantom.A2A.Agent
  def cancel_task(%Task{id: task_id} = task, ctx) do
    case {mcp_task(task_id, ctx), ctx.agent.opts[:fallback]} do
      {:error, fallback} when not is_nil(fallback) -> fallback.cancel_task(task, ctx)
      _mcp_task -> cancel_mcp_task(task_id, ctx)
    end
  end

  defp cancel_mcp_task(task_id, ctx) do
    router = ctx.session.router

    with {:ok, task} <- mcp_task(task_id, ctx),
         true <- function_exported?(router, :cancel_task, 2),
         :ok <- router.cancel_task(task, ctx.session) do
      get_task(task_id, ctx)
    else
      _not_cancelable -> {:error, :not_cancelable}
    end
  end

  defp mcp_task(task_id, ctx) do
    router = ctx.session.router

    with true <- Phantom.Router.tasks_enabled?(router),
         {:ok, %Phantom.Tasks{} = task} <- router.get_task(task_id, ctx.session) do
      {:ok, task}
    else
      _not_found -> :error
    end
  end

  # The client answers a task's input requests with a data part:
  # {"inputResponses": {key: response}}.
  defp continue_task(task_id, message, ctx) do
    router = ctx.session.router

    responses =
      Enum.find_value(message.parts, %{}, fn
        %Part{data: %{"inputResponses" => %{} = responses}} -> responses
        _part -> nil
      end)

    with {:ok, task} <- mcp_task(task_id, ctx),
         outstanding when map_size(outstanding) > 0 <-
           Map.take(responses, Map.keys(task.input_requests)),
         true <- function_exported?(router, :update_task, 3),
         :ok <- router.update_task(task, outstanding, ctx.session),
         {:ok, task} <- mcp_task(task_id, ctx) do
      {:reply, to_a2a(task), ctx}
    else
      {:error, error} ->
        {:error, error(error), ctx}

      _nothing_to_answer ->
        keys =
          case mcp_task(task_id, ctx) do
            {:ok, task} -> Map.keys(task.input_requests)
            :error -> []
          end

        message =
          ~s(Answer the task's input requests with a data part {"inputResponses": {...}}: ) <>
            Enum.join(keys, ", ")

        {:error, Error.invalid_params(message), ctx}
    end
  end

  @states %{
    working: :working,
    input_required: :input_required,
    completed: :completed,
    failed: :failed,
    cancelled: :canceled
  }

  # An MCP task as an A2A task. MCP tasks have no context, so each is its own.
  defp to_a2a(%Phantom.Tasks{} = task) do
    %Task{
      id: task.id,
      context_id: task.id,
      status: %TaskStatus{
        state: Map.fetch!(@states, task.status),
        message: status_message(task),
        timestamp: task.last_updated_at
      },
      artifacts: artifacts(task)
    }
  end

  defp status_message(task) do
    error = if task.error, do: json(task.error)["message"]

    input_requests =
      if task.input_requests != %{},
        do: [Part.data(%{"inputRequests" => json(task.input_requests)})],
        else: []

    texts = for text <- [task.status_message, error], is_binary(text), do: Part.text(text)

    case texts ++ input_requests do
      [] -> nil
      parts -> Message.agent(parts, task_id: task.id, context_id: task.id)
    end
  end

  defp artifacts(%Phantom.Tasks{status: :completed, result: %{} = result}) do
    {parts, _error?} = result_parts(result)
    [Artifact.new("result", parts)]
  end

  defp artifacts(_task), do: []

  defp no_tool(message, ctx) do
    case ctx.agent.opts[:fallback] do
      nil ->
        names =
          Enum.map_join(tools(ctx.session.router, ctx.session, ctx.agent.opts), ", ", & &1.name)

        text =
          ~s(Send a data part naming a tool, such as {"tool": "name", "arguments": {}}. ) <>
            "Tools: #{names}"

        {:reply, Message.agent(text), ctx}

      fallback ->
        fallback.handle_message(message, ctx)
    end
  end

  defp tools(router, session, opts) do
    if not Phantom.Cache.initialized?(router), do: Phantom.Cache.register(router)
    available = Phantom.Cache.list(session, router, :tools)

    case opts[:tools] do
      nil -> available
      names -> Enum.filter(available, &(&1.name in names))
    end
  end

  defp to_skill(tool) do
    %AgentSkill{
      id: tool.name,
      name: tool.name |> String.replace("_", " ") |> String.capitalize(),
      description: tool.description || tool.name,
      tags: ["mcp-tool"]
    }
  end

  # The tool as `tools/list` lists it, with string keys.
  defp tool_json(tool), do: tool |> Phantom.Tool.to_json() |> JSON.encode!() |> JSON.decode!()

  defp reply(result) do
    {parts, error?} = result_parts(result)
    Message.agent(parts, metadata: if(error?, do: %{"mcp/isError" => true}))
  end

  # A `CallToolResult` as parts, and whether it is an error.
  defp result_parts(result) do
    result = json(result)
    content = Enum.flat_map(result["content"] || [], &part/1)

    structured =
      if Map.has_key?(result, "structuredContent"),
        do: [Part.data(result["structuredContent"])],
        else: []

    # A message or artifact must have a part, even if the tool said nothing.
    parts =
      case content ++ structured do
        [] -> [Part.text("")]
        parts -> parts
      end

    {parts, result["isError"] == true}
  end

  defp json(term), do: term |> JSON.encode!() |> JSON.decode!()

  defp part(%{"type" => "text", "text" => text}), do: [Part.text(text)]

  defp part(%{"type" => type, "data" => data} = content) when type in ["image", "audio"],
    do: [Part.raw(Base.decode64!(data), media_type: content["mimeType"])]

  defp part(%{"type" => "resource_link", "uri" => uri} = link),
    do: [Part.url(uri, filename: link["name"], media_type: link["mimeType"])]

  defp part(%{"type" => "resource", "resource" => %{"text" => text} = resource}),
    do: [Part.text(text, media_type: resource["mimeType"], metadata: %{"uri" => resource["uri"]})]

  defp part(%{"type" => "resource", "resource" => %{"blob" => blob} = resource}),
    do: [
      Part.raw(Base.decode64!(blob),
        media_type: resource["mimeType"],
        metadata: %{"uri" => resource["uri"]}
      )
    ]

  defp part(_content), do: []

  defp error(%{code: -32602, message: message}), do: Error.invalid_params(message)
  defp error(%{code: code, message: message}), do: %Error{code: code, message: message}

  defp error(other) do
    Logger.warning("A2A bridge tool call failed: #{inspect(other)}")
    Error.internal_error()
  end
end

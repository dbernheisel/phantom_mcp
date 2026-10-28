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
  that lists the tools.

  ## Options

    * `:tools` - the names of the tools to serve (default: every tool)
    * `:name`, `:description` - for the card (default: the router's name and
      instructions)
    * `:fallback` - a `Phantom.A2A.Agent` for messages that name no tool

  Tools that answer from another process (`{:noreply, session}`) block the
  request until they respond. A tool that elicits gets `:not_supported`, as
  there is no MCP client to ask.
  """

  use Phantom.A2A.Agent,
    name: "MCP tools",
    description: "Calls MCP tools",
    input_modes: ~w[application/json text/plain],
    output_modes: ~w[application/json text/plain]

  alias Phantom.A2A.{AgentSkill, Error, Message, Part}

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

  defp call(name, arguments, ctx) do
    router = ctx.session.router

    if Enum.any?(tools(router, ctx.session, ctx.agent.opts), &(&1.name == name)) do
      case Phantom.Router.call_tool(ctx.session, name, arguments) do
        {:ok, result} ->
          {:reply, reply(result), ctx}

        {:error, :timeout} ->
          {:error, %Error{code: -32603, message: "Tool #{name} timed out"}, ctx}

        {:error, error} ->
          {:error, error(error), ctx}
      end
    else
      {:error, Error.invalid_params("Unknown tool: #{name}"), ctx}
    end
  end

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
    result = result |> JSON.encode!() |> JSON.decode!()
    content = Enum.flat_map(result["content"] || [], &part/1)

    structured =
      if Map.has_key?(result, "structuredContent"),
        do: [Part.data(result["structuredContent"])],
        else: []

    metadata = if result["isError"] == true, do: %{"mcp/isError" => true}

    Message.agent(content ++ structured, metadata: metadata)
  end

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
  defp error(other), do: %Error{code: -32603, message: inspect(other)}
end

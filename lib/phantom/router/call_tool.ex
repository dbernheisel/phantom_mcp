defmodule Phantom.Router.CallTool do
  @moduledoc false
  # Calls a router's tool in the calling process, which stands in for the
  # session the tool would answer, like `Phantom.Test.call_tool/4` does.

  alias Phantom.{Cache, Request, Session}

  # Casts a tool may send its session (see `Phantom.Session.handle_cast/2`).
  @session_casts [:finish, :ping, :tools_updated, :prompts_updated, :resources_updated]
  @session_cast_tags [
    :send,
    :notify,
    :log,
    :log_legacy,
    :progress,
    :respond,
    :release_worker,
    :subscribe_resource,
    :unsubscribe_resource,
    :resource_updated,
    :set_log_level
  ]

  def call(%Session{router: router} = session, name, args, opts) do
    if not Cache.initialized?(router), do: Cache.register(router)

    meta = if opts[:tasks], do: tasks_meta(), else: nil
    params = %{"name" => to_string(name), "arguments" => stringify_keys(args)}
    params = if meta, do: Map.put(params, "_meta", meta), else: params

    request = %Request{
      id: UUIDv7.generate(),
      method: "tools/call",
      params: params,
      meta: meta,
      type: "message"
    }

    session = %{session | pid: self(), request: request}
    timeout = Keyword.get(opts, :timeout, :timer.seconds(60))

    try do
      router.dispatch_method(["tools/call", params, request, session])
      |> case do
        {:reply, result, _session} -> {:ok, result}
        {:noreply, _session} -> await(request.id, deadline(timeout), opts[:on_progress])
        {:error, error, _session} -> {:error, error}
        {:error, error} -> {:error, error}
      end
      |> fetch_task(router, session)
    after
      drain(request.id)
    end
  end

  # A stateless request that declares the Tasks extension, so a tool may
  # answer with a `Phantom.Tasks`.
  defp tasks_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{
        "extensions" => %{Phantom.Tasks.extension() => %{}}
      }
    }
  end

  # A tool that answered with a task sent its `CreateTaskResult`; return the task.
  defp fetch_task({:ok, %{resultType: "task", taskId: id}}, router, session) do
    case router.get_task(id, session) do
      {:ok, %Phantom.Tasks{} = task} -> {:ok, task}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_task(result, _router, _session), do: result

  defp await(request_id, deadline, on_progress) do
    receive do
      {:"$gen_cast", {:respond, ^request_id, %{result: result}}} ->
        {:ok, result}

      {:"$gen_cast", {:respond, ^request_id, %{error: error}}} ->
        {:error, error}

      {:"$gen_cast", {:progress, _token, progress, total, message}}
      when is_function(on_progress, 3) ->
        on_progress.(progress, total, message)
        await(request_id, deadline, on_progress)
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  defp drain(request_id) do
    receive do
      {:"$gen_cast", {:respond, ^request_id, _response}} ->
        drain(request_id)

      {:"$gen_cast", msg} when msg in @session_casts ->
        drain(request_id)

      {:"$gen_cast", msg} when is_tuple(msg) and elem(msg, 0) in @session_cast_tags ->
        drain(request_id)
    after
      0 -> :ok
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp stringify_keys(args) when is_list(args), do: args |> Map.new() |> stringify_keys()

  defp stringify_keys(args) when is_map(args),
    do: Map.new(args, fn {key, value} -> {to_string(key), value} end)
end

defmodule Phantom.Test.NodeCase do
  @moduledoc """
  ExUnit case template for distributed Phantom MCP tests.

  Provides helpers for executing code on remote nodes and making
  HTTP/SSE requests to Bandit servers running on peer nodes.

  Tests using this case are tagged `:clustered` and run sequentially.
  """

  @timeout 5_000

  defmacro __using__(opts \\ []) do
    quote do
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, false))
      import unquote(__MODULE__)
      @moduletag :clustered
      @timeout unquote(@timeout)
    end
  end

  @doc """
  Execute `func` on the remote `node` and return the result.
  """
  def call_node(node, func) do
    parent = self()
    ref = make_ref()

    _pid =
      Node.spawn_link(node, fn ->
        result = func.()
        send(parent, {ref, result})
        mon = Process.monitor(parent)

        receive do
          {:DOWN, ^mon, :process, _, _} -> :ok
        end
      end)

    receive do
      {^ref, result} -> result
    after
      @timeout -> raise "call_node to #{node} timed out"
    end
  end

  @doc """
  POST a JSON-RPC request to a node's Bandit port.

  Returns a `Req.Response` with `into: :self` for streaming SSE.
  """
  def post_mcp(port, body, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)

    headers = [
      {"content-type", "application/json"},
      {"accept", "text/event-stream, application/json"}
    ]

    headers =
      if session_id, do: [{"mcp-session-id", session_id} | headers], else: headers

    Req.post!("http://127.0.0.1:#{port}/",
      json: body,
      headers: headers,
      into: :self,
      receive_timeout: @timeout
    )
  end

  @doc """
  Open a GET SSE stream to a node's Bandit port.
  """
  def open_sse(port, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    headers = [{"accept", "text/event-stream"}]

    headers =
      if session_id, do: [{"mcp-session-id", session_id} | headers], else: headers

    Req.get!("http://127.0.0.1:#{port}/",
      headers: headers,
      into: :self,
      receive_timeout: @timeout
    )
  end

  @doc """
  Receive and parse SSE events from a streaming Req response.

  Returns `{messages, ref, remaining_buffer}` on success,
  `{:closed, ref, buffer}` when the stream ends, or
  `{:timeout, ref, buffer}` on timeout.
  """
  def receive_sse_event(resp, timeout \\ 5_000) do
    ref = resp.body.ref
    receive_sse_loop(ref, "", timeout)
  end

  @doc """
  Continue receiving SSE events with an existing ref and buffer.
  """
  def receive_sse_event(_resp, ref, buffer, timeout \\ 5_000) do
    receive_sse_loop(ref, buffer, timeout)
  end

  @doc """
  Keep reading SSE event batches until `match_fn` returns truthy for a message.
  Returns the matching message or nil on timeout.
  """
  def poll_for_sse_event(%Req.Response{} = resp, timeout, match_fn) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_sse_loop(resp.body.ref, "", deadline, match_fn)
  end

  def poll_for_sse_event(_resp, ref, buffer, timeout, match_fn) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_sse_loop(ref, buffer, deadline, match_fn)
  end

  defp poll_sse_loop(ref, buffer, deadline, match_fn) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case receive_sse_loop(ref, buffer, remaining) do
      {messages, ref, buffer} when is_list(messages) ->
        case Enum.find(messages, match_fn) do
          nil -> poll_sse_loop(ref, buffer, deadline, match_fn)
          found -> found
        end

      _timeout_or_closed ->
        nil
    end
  end

  defp receive_sse_loop(ref, buffer, timeout) do
    receive do
      {^ref, {:data, chunk}} ->
        buffer = buffer <> chunk

        case parse_sse_events(buffer) do
          {[], remaining} ->
            receive_sse_loop(ref, remaining, timeout)

          {events, remaining} ->
            messages =
              Enum.flat_map(events, fn event ->
                case event do
                  %{data: data} when is_binary(data) and data != "" ->
                    case JSON.decode(data) do
                      {:ok, parsed} -> [parsed]
                      _ -> []
                    end

                  _ ->
                    []
                end
              end)

            case messages do
              [] -> receive_sse_loop(ref, remaining, timeout)
              msgs -> {msgs, ref, remaining}
            end
        end

      {^ref, :done} ->
        {:closed, ref, buffer}
    after
      timeout -> {:timeout, ref, buffer}
    end
  end

  defp parse_sse_events(buffer) do
    case String.split(buffer, "\n\n", parts: 2) do
      [complete, rest] ->
        event = parse_single_event(complete)
        {more, remaining} = parse_sse_events(rest)
        {[event | more], remaining}

      [incomplete] ->
        {[], incomplete}
    end
  end

  defp parse_single_event(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        ["id", value] -> Map.put(acc, :id, value)
        ["event", value] -> Map.put(acc, :event, value)
        ["data", value] -> Map.update(acc, :data, value, &(&1 <> value))
        _ -> acc
      end
    end)
  end

  @doc """
  Extract the `mcp-session-id` header from a Req response.
  """
  def session_id(%Req.Response{} = resp) do
    case resp.headers do
      %{"mcp-session-id" => [value | _]} -> value
      _ -> nil
    end
  end

  @doc """
  Wait until a session is visible in the Tracker on a given node.
  Polls `get_session` since Phoenix.Tracker's `handle_diff` uses
  `direct_broadcast!` which only broadcasts to the local node.
  """
  def await_session_tracked(node, session_id, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_session(node, session_id, deadline)
  end

  @doc """
  Wait until a resource subscription is visible in the Tracker on a given node.
  """
  def await_resource_tracked(node, uri, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_resource(node, uri, deadline)
  end

  defp do_await_resource(node, uri, deadline) do
    result =
      :rpc.call(node, Phoenix.Tracker, :get_by_key, [
        Phantom.Tracker,
        Phantom.Tracker.resource_subscription_topic(),
        uri
      ])

    case result do
      [{_, _} | _] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          do_await_resource(node, uri, deadline)
        else
          raise "Resource #{uri} not visible on #{node} within timeout"
        end
    end
  end

  defp do_await_session(node, session_id, deadline) do
    case :rpc.call(node, Phantom.Tracker, :get_session, [session_id]) do
      pid when is_pid(pid) ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          do_await_session(node, session_id, deadline)
        else
          raise "Session #{session_id} not visible on #{node} within timeout"
        end
    end
  end

  @doc """
  POST an `initialize` request and return the session ID.
  """
  def initialize(port) do
    resp =
      post_mcp(port, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-06-18",
          capabilities: %{roots: %{}, sampling: %{}, elicitation: %{}},
          clientInfo: %{name: "DistributedTestClient", version: "1.0"}
        }
      })

    sid = session_id(resp)
    # Drain the initialize response SSE events
    receive_sse_event(resp)
    sid
  end
end

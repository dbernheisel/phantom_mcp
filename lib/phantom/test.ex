defmodule Phantom.Test do
  @moduledoc """
  Test helpers for asserting on tools, prompts, and resources defined in a
  `Phantom.Router`.

  Drives router handlers directly without booting an HTTP transport, so
  unit-level tests can assert on the *final* response of a tool/prompt/
  resource regardless of whether the handler returned synchronously
  (`{:reply, _, _}`) or asynchronously (`{:noreply, _}` + `Session.respond/2`
  from a `Task`).

  ## Example

      defmodule MyApp.MCP.RouterTest do
        use ExUnit.Case, async: true
        import Phantom.Test

        setup do
          Phantom.Test.start(router: MyApp.MCP.Router)
          {:ok, session: build_session(MyApp.MCP.Router)}
        end

        test "echo tool", %{session: session} do
          result = call_tool(session, :echo_tool, %{message: "hi"})
          assert_tool_text(result, "hi")
        end

        test "tool that elicits info", %{session: session} do
          expect_elicit(fn _elicit ->
            {:ok, %{"action" => "accept", "content" => %{"name" => "Joe"}}}
          end)

          result = call_tool(session, :elicit_tool, %{})
          assert_tool_text(result, ~r/Joe/)
        end
      end

  ## PubSub

  PubSub-driven features (`Phantom.Tracker`, resource subscriptions,
  list-changed notifications across nodes) are opt-in. Pass `:pubsub`
  to `start/1` to enable them:

      Phantom.Test.start(router: MyApp.MCP.Router, pubsub: MyApp.PubSub)

  Side-channel assertions (`assert_progress_seen/1`, `assert_client_log_seen/1`)
  work without PubSub: they read messages cast directly to the test process.
  """

  import ExUnit.Assertions

  alias Phantom.Cache
  alias Phantom.Request
  alias Phantom.Session

  @default_timeout 1_000

  # Phantom session GenServer cast shapes (see lib/phantom/session.ex
  # `handle_cast/2`). Anything matching these is consumed silently;
  # other casts to the test pid are left in the mailbox.
  @session_internal_atoms [:finish, :ping, :tools_updated, :prompts_updated, :resources_updated]
  @session_internal_tags [
    :subscribe_resource,
    :unsubscribe_resource,
    :resource_updated,
    :set_log_level,
    :respond
  ]

  defmodule TimeoutError do
    @moduledoc "Raised when a blocking dispatcher does not receive a response in time."
    defexception [:message]
  end

  @doc """
  Register the router with `Phantom.Cache` and, optionally, start
  `Phantom.Tracker` against the given `:pubsub`.

  Options:
    * `:router` - required. The MCP router module.
    * `:pubsub` - optional. Phoenix.PubSub server name. If supplied,
      ensures `Phantom.Tracker` is running and bound to it.
  """
  @spec start(keyword()) :: :ok
  def start(opts) do
    router = Keyword.fetch!(opts, :router)
    Cache.register(router)

    case Keyword.get(opts, :pubsub) do
      nil ->
        :ok

      pubsub ->
        ensure_tracker_started!(pubsub)
        :ok
    end
  end

  @doc """
  Build a `Phantom.Session` for use with the blocking dispatchers below.

  The session's `:pid` and `:elicit` are wired during dispatch — you do
  not need to set them. Options:

    * `:id` - session id (default: a fresh UUIDv7)
    * `:assigns` - session assigns (default: `%{}`)
    * `:allowed_tools` / `:allowed_prompts` / `:allowed_resource_templates`
      - allow-lists, like in `c:Phantom.Router.connect/2`.
    * `:pubsub` - attach a pubsub server to the session.
    * `:client_capabilities` - override the default capabilities map.
      Defaults to `%{elicitation: %{"url" => %{}}, sampling: %{}, roots: %{}}`
      so both form-mode and url-mode elicitation are supported in tests.
  """
  @spec build_session(module(), keyword()) :: Session.t()
  def build_session(router, opts \\ []) do
    capabilities = Keyword.get(opts, :client_capabilities, default_capabilities())

    Session.new(opts[:id],
      router: router,
      pubsub: opts[:pubsub],
      assigns: opts[:assigns] || %{},
      allowed_tools: opts[:allowed_tools],
      allowed_prompts: opts[:allowed_prompts],
      allowed_resource_templates: opts[:allowed_resource_templates],
      client_capabilities: capabilities
    )
  end

  @doc """
  Build a fresh `Phantom.Request` struct with a random id and the given method.
  """
  def build_request(method, opts \\ []) do
    %Request{
      id: Keyword.get_lazy(opts, :id, &UUIDv7.generate/0),
      method: method,
      params: Keyword.get(opts, :params, %{}),
      type: "message"
    }
  end

  @doc """
  Register a responder for form-mode elicitations.

  The responder receives a `Phantom.Elicit` struct and must return
  `{:ok, response_map}` (e.g. `{:ok, %{"action" => "accept", "content" => %{...}}}`),
  `:error`, `:not_supported`, or `:timeout`.

  Stored in the calling test process; ExUnit isolates per test.
  """
  @spec expect_elicit((Phantom.Elicit.t() -> any())) :: :ok
  def expect_elicit(fun) when is_function(fun, 1) do
    Process.put({__MODULE__, :elicit_responder, :form}, fun)
    :ok
  end

  @doc """
  Register a responder for url-mode elicitations. See `expect_elicit/1`.
  """
  @spec expect_elicit_url((Phantom.Elicit.t() -> any())) :: :ok
  def expect_elicit_url(fun) when is_function(fun, 1) do
    Process.put({__MODULE__, :elicit_responder, :url}, fun)
    :ok
  end

  @doc """
  Drain progress notifications and client logs cast to the test mailbox.
  """
  @spec flush_notifications() :: :ok
  def flush_notifications do
    receive do
      {:phantom_test_progress, _} -> flush_notifications()
      {:phantom_test_client_log, _, _, _, _} -> flush_notifications()
      {:phantom_test_notify, _} -> flush_notifications()
    after
      0 -> :ok
    end
  end

  @doc """
  Call a tool by name and block until the final response arrives.

  Returns the unwrapped `result` payload (the value the MCP client
  would see under `"result"`) for `{:reply, _, _}` and `Session.respond/2`
  paths, or `{:jsonrpc_error, error_map}` if the dispatcher returned an
  error tuple (e.g. validation failure, `{:elicitation_required, _}`).

  Options:
    * `:timeout` - ms to wait for an async response (default: 1000)
    * `:progress_token` - sets `params._meta.progressToken` on the request
  """
  @spec call_tool(Session.t(), atom() | String.t(), map() | keyword(), keyword()) :: any()
  def call_tool(session, name, args \\ %{}, opts \\ []) do
    params = %{"name" => to_string(name), "arguments" => stringify_keys(args)}
    dispatch_blocking(session, "tools/call", params, opts)
  end

  @doc """
  Read a resource by name and path params; blocks until the final response.

  Returns `{:ok, uri, content}` on success, or
  `{:jsonrpc_error, error_map}` if dispatch returned an error tuple.

  Path params accept atom or string keys.
  """
  @spec read_resource(Session.t(), atom() | String.t(), keyword() | map(), keyword()) :: any()
  def read_resource(session, name, path_params \\ [], opts \\ []) do
    case session.router.resource_uri(session, name, path_params) do
      {:ok, uri} ->
        params = %{"uri" => uri}

        case dispatch_blocking(session, "resources/read", params, opts) do
          {:jsonrpc_error, _} = err ->
            err

          %{contents: [first | _]} ->
            {:ok, uri, first}

          %{contents: []} ->
            {:ok, uri, nil}

          other ->
            {:ok, uri, other}
        end

      {:error, reason} ->
        {:jsonrpc_error, Request.invalid_params(%{reason: reason})}
    end
  end

  @doc """
  Get a prompt by name. Blocks until the final response arrives.
  """
  @spec get_prompt(Session.t(), atom() | String.t(), map() | keyword(), keyword()) :: any()
  def get_prompt(session, name, args \\ %{}, opts \\ []) do
    params = %{"name" => to_string(name), "arguments" => stringify_keys(args)}
    dispatch_blocking(session, "prompts/get", params, opts)
  end

  @doc """
  Run prompt completion. Returns the dispatcher's reply map (under `:completion`)
  or `{:jsonrpc_error, error_map}`.
  """
  @spec complete_prompt(Session.t(), atom() | String.t(), String.t(), String.t(), keyword()) ::
          any()
  def complete_prompt(session, prompt_name, arg, value, opts \\ []) do
    params = %{
      "ref" => %{"type" => "ref/prompt", "name" => to_string(prompt_name)},
      "argument" => %{"name" => arg, "value" => value}
    }

    dispatch_blocking(session, "completion/complete", params, opts)
  end

  @doc """
  Run resource completion against a URI template. See `complete_prompt/5`.
  """
  @spec complete_resource(Session.t(), String.t(), String.t(), String.t(), keyword()) :: any()
  def complete_resource(session, uri_template, arg, value, opts \\ []) do
    params = %{
      "ref" => %{"type" => "ref/resource", "uri" => uri_template},
      "argument" => %{"name" => arg, "value" => value}
    }

    dispatch_blocking(session, "completion/complete", params, opts)
  end

  @doc """
  Dispatch `resources/list` with an optional cursor.
  """
  @spec list_resources(Session.t(), String.t() | nil, keyword()) :: any()
  def list_resources(session, cursor \\ nil, opts \\ []) do
    dispatch_blocking(session, "resources/list", %{"cursor" => cursor}, opts)
  end

  @doc false
  def invoke_elicit_responder(%Phantom.Elicit{mode: mode} = elicitation) do
    case Process.get({__MODULE__, :elicit_responder, mode}) do
      nil ->
        raise """
        no elicit responder registered for mode #{inspect(mode)}.
        Call Phantom.Test.expect_elicit/1 (or expect_elicit_url/1) before
        dispatching a tool that uses Session.elicit/2.
        """

      fun when is_function(fun, 1) ->
        fun.(elicitation)
    end
  end

  ## Internals

  defp default_capabilities do
    %{
      elicitation: %{"url" => %{}},
      sampling: %{},
      roots: %{},
      ui: false
    }
  end

  defp dispatch_blocking(session, method, params, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    request = build_request(method, params: maybe_with_progress(opts))

    session = %{
      session
      | pid: self(),
        elicit: build_elicit_fun(),
        request: request
    }

    try do
      result = session.router.dispatch_method([method, params, request, session])
      handle_dispatch_result(result, request.id, timeout)
    after
      drain_session_casts(request.id)
    end
  end

  defp maybe_with_progress(opts) do
    case Keyword.get(opts, :progress_token) do
      nil -> %{}
      token -> %{"_meta" => %{"progressToken" => token}}
    end
  end

  defp build_elicit_fun do
    fn elicitation, _timeout -> invoke_elicit_responder(elicitation) end
  end

  defp handle_dispatch_result({:reply, payload, _session}, _request_id, _timeout), do: payload

  defp handle_dispatch_result({:noreply, _session}, request_id, timeout) do
    await_response(request_id, timeout, deadline(timeout))
  end

  defp handle_dispatch_result({:error, error, _session}, _request_id, _timeout) do
    {:jsonrpc_error, error}
  end

  defp handle_dispatch_result({:error, error}, _request_id, _timeout) do
    {:jsonrpc_error, error}
  end

  defp deadline(:infinity), do: :infinity

  defp deadline(timeout) when is_integer(timeout),
    do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp await_response(request_id, timeout, deadline) do
    receive do
      {:"$gen_cast", {:respond, ^request_id, %{result: result}}} ->
        result

      {:"$gen_cast", {:respond, ^request_id, %{error: error}}} ->
        {:jsonrpc_error, error}

      {:"$gen_call", from, {:elicit, elicitation, _tool_call_id}} ->
        response = invoke_elicit_responder(elicitation)
        GenServer.reply(from, response)
        await_response(request_id, timeout, deadline)

      {:"$gen_cast", {:send, payload}} ->
        send(self(), {:phantom_test_progress, payload})
        await_response(request_id, timeout, deadline)

      {:"$gen_cast", {:notify, payload}} ->
        send(self(), {:phantom_test_notify, payload})
        await_response(request_id, timeout, deadline)

      {:"$gen_cast", {:log, level, level_name, domain, payload}} ->
        send(self(), {:phantom_test_client_log, level, level_name, domain, payload})
        await_response(request_id, timeout, deadline)

      {:"$gen_cast", msg}
      when msg in @session_internal_atoms
      when is_tuple(msg) and elem(msg, 0) in @session_internal_tags ->
        await_response(request_id, timeout, deadline)
    after
      remaining(deadline) ->
        raise TimeoutError,
          message:
            "Phantom.Test: no response for request #{inspect(request_id)} within #{timeout}ms"
    end
  end

  # After dispatch settles, surface any session casts that arrived
  # outside the await loop (e.g. notifications fired before dispatch
  # returned, or after a synchronous reply) as tagged messages so
  # `Phantom.Test.Assertions.assert_progress_seen/1` and friends can
  # see them.
  defp drain_session_casts(request_id) do
    receive do
      {:"$gen_cast", {:respond, ^request_id, _}} ->
        drain_session_casts(request_id)

      {:"$gen_cast", {:send, payload}} ->
        send(self(), {:phantom_test_progress, payload})
        drain_session_casts(request_id)

      {:"$gen_cast", {:notify, payload}} ->
        send(self(), {:phantom_test_notify, payload})
        drain_session_casts(request_id)

      {:"$gen_cast", {:log, level, level_name, domain, payload}} ->
        send(self(), {:phantom_test_client_log, level, level_name, domain, payload})
        drain_session_casts(request_id)

      {:"$gen_cast", msg}
      when msg in @session_internal_atoms
      when is_tuple(msg) and elem(msg, 0) in @session_internal_tags ->
        drain_session_casts(request_id)
    after
      0 -> :ok
    end
  end

  # `Phantom.Tracker.start_link/1` returns the literal `:error` when
  # `phoenix_pubsub` isn't loaded (its compile-time fallback). Dialyzer
  # only sees the loaded branch's spec in this build, so it flags the
  # `:error` clause as unreachable — but it's reachable in environments
  # without `phoenix_pubsub`.
  @dialyzer {:no_match, ensure_tracker_started!: 1}
  @dialyzer {:no_unused, raise_no_pubsub: 0}
  defp ensure_tracker_started!(pubsub) do
    case Process.whereis(Phantom.Tracker) do
      nil ->
        case Phantom.Tracker.start_link(name: Phantom.Tracker, pubsub_server: pubsub) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          :error -> raise_no_pubsub()
        end

      _pid ->
        :ok
    end
  end

  defp raise_no_pubsub do
    raise """
    Phantom.Test.start/1 received `:pubsub` but `:phoenix_pubsub` is not
    loaded. Add `{:phoenix_pubsub, "~> 2.0"}` to your test dependencies.
    """
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(list) when is_list(list) do
    Map.new(list, fn {k, v} -> {to_string(k), v} end)
  end

  ## Assertions
  ##
  ## Each matcher operates on the value returned by a dispatcher above
  ## and either returns the result for chaining or raises on mismatch.
  ## Side-channel matchers (`assert_progress_seen/1`, `assert_client_log_seen/1`)
  ## drain messages from the test mailbox and don't take a result argument.

  @doc """
  Assert the tool returned a text content payload.

  `expected` may be a binary or a regex.
  """
  def assert_tool_text(result, expected) do
    text = extract_text(result)
    assert_match(text, expected, "tool text")
    result
  end

  @doc """
  Assert the tool returned an error response (`isError: true`) with the given message.
  """
  def assert_tool_error(result, expected) do
    case result do
      %{isError: true, content: [%{type: :text, text: text} | _]} ->
        assert_match(text, expected, "tool error text")
        result

      other ->
        flunk("expected tool error response, got: #{inspect(other)}")
    end
  end

  @doc "Assert the tool returned image content."
  def assert_tool_image(result, opts \\ []) do
    assert_content_type(result, :image, opts)
    result
  end

  @doc "Assert the tool returned audio content."
  def assert_tool_audio(result, opts \\ []) do
    assert_content_type(result, :audio, opts)
    result
  end

  @doc "Assert the tool returned a resource link."
  def assert_tool_resource_link(result, opts \\ []) do
    case result do
      %{content: [%{type: :resource_link} = link | _]} ->
        match_attrs(link, opts, "resource link")
        result

      other ->
        flunk("expected resource_link tool response, got: #{inspect(other)}")
    end
  end

  @doc "Assert the tool returned an embedded resource."
  def assert_tool_embedded_resource(result, opts \\ []) do
    case result do
      %{content: [%{type: :resource, resource: resource} | _]} ->
        match_attrs(resource, opts, "embedded resource")
        result

      other ->
        flunk("expected embedded resource tool response, got: #{inspect(other)}")
    end
  end

  @doc """
  Assert a `read_resource/3` result contains text content matching `expected`.

  Accepts both `{:ok, uri, content}` and a raw content map.
  """
  def assert_resource_text(result, expected) do
    text = resource_text(result)
    assert_match(text, expected, "resource text")
    result
  end

  @doc """
  Assert a `read_resource/3` result contains a base64-encoded blob.

  When `:mime_type` is provided, asserts on it too.
  """
  def assert_resource_blob(result, opts \\ []) do
    content =
      case result do
        {:ok, _uri, content} -> content
        %{} = content -> content
      end

    assert is_binary(content[:blob]) or is_binary(content["blob"]),
           "expected resource blob content, got: #{inspect(content)}"

    if mime = Keyword.get(opts, :mime_type) do
      actual = content[:mimeType] || content["mimeType"]

      assert actual == mime,
             "expected mime_type #{inspect(mime)}, got #{inspect(actual)}"
    end

    result
  end

  @doc """
  Assert a `get_prompt/3` result contains a message matching `opts`.

  Options: `:role`, `:type`, `:text` (binary or regex).
  """
  def assert_prompt_message(result, opts) when is_list(opts) do
    case result do
      %{messages: messages} ->
        role = Keyword.get(opts, :role)
        type = Keyword.get(opts, :type)
        text = Keyword.get(opts, :text)

        match? =
          Enum.any?(messages, fn %{role: r, content: c} ->
            (is_nil(role) or r == role) and
              (is_nil(type) or c[:type] == type) and
              (is_nil(text) or text_matches?(c[:text], text))
          end)

        assert match?,
               "no prompt message matched #{inspect(opts)}.\nMessages: #{inspect(messages)}"

        result

      other ->
        flunk("expected prompt response with :messages, got: #{inspect(other)}")
    end
  end

  @doc """
  Assert the dispatcher returned a JSON-RPC error.

  Options: `:code`, `:message`, `:data`.
  """
  def assert_jsonrpc_error(result, opts) when is_list(opts) do
    case result do
      {:jsonrpc_error, error} ->
        if code = Keyword.get(opts, :code) do
          assert error[:code] == code,
                 "expected error code #{code}, got #{inspect(error[:code])}"
        end

        if msg = Keyword.get(opts, :message) do
          assert_match(error[:message], msg, "error message")
        end

        if data = Keyword.get(opts, :data) do
          assert error[:data] == data,
                 "expected error data #{inspect(data)}, got #{inspect(error[:data])}"
        end

        result

      other ->
        flunk("expected {:jsonrpc_error, _}, got: #{inspect(other)}")
    end
  end

  @doc """
  Assert the dispatcher returned an `:elicitation_required` JSON-RPC error
  (code -32042).

  Options: `:message` matches the elicitation message string.
  """
  def assert_elicitation_required(result, opts \\ []) do
    case result do
      {:jsonrpc_error, %{code: -32042, data: %{elicitations: elicitations}} = error} ->
        if msg = Keyword.get(opts, :message) do
          match? =
            Enum.any?(elicitations, fn elicit ->
              text_matches?(elicit[:message] || elicit["message"], msg)
            end)

          assert match?,
                 "no elicitation matched message #{inspect(msg)}.\nGot: #{inspect(elicitations)}"
        end

        {:jsonrpc_error, error}

      other ->
        flunk("expected elicitation_required error (code -32042), got: #{inspect(other)}")
    end
  end

  @doc """
  Assert that a progress notification was emitted during the most recent
  dispatch.

  Options:
    * `:progress` - exact value
    * `:total` - exact total
    * `:steps` - exact number of progress notifications observed

  Drains any matching messages from the mailbox.
  """
  def assert_progress_seen(opts \\ []) do
    notifications = drain(:phantom_test_progress)

    assert notifications != [],
           "expected at least one progress notification, got none"

    if steps = Keyword.get(opts, :steps) do
      assert length(notifications) == steps,
             "expected #{steps} progress notifications, got #{length(notifications)}"
    end

    if progress = Keyword.get(opts, :progress) do
      params = Enum.map(notifications, & &1[:params])

      assert Enum.any?(params, &(&1[:progress] == progress)),
             "no progress notification matched progress=#{progress}.\nGot: #{inspect(params)}"
    end

    if total = Keyword.get(opts, :total) do
      params = Enum.map(notifications, & &1[:params])

      assert Enum.any?(params, &(&1[:total] == total)),
             "no progress notification matched total=#{total}.\nGot: #{inspect(params)}"
    end

    notifications
  end

  @doc "Refute that any progress notification was emitted."
  def refute_progress_seen do
    notifications = drain(:phantom_test_progress)
    assert notifications == [], "expected no progress, got: #{inspect(notifications)}"
    :ok
  end

  @doc """
  Assert that a client log was emitted during the most recent dispatch.

  Options: `:level` (atom), `:domain` (string), `:data` (map for partial match).
  """
  def assert_client_log_seen(opts \\ []) do
    logs = drain_logs()

    assert logs != [], "expected at least one client log, got none"

    expected_level = Keyword.get(opts, :level)
    expected_domain = Keyword.get(opts, :domain)
    expected_data = Keyword.get(opts, :data)

    match? =
      Enum.any?(logs, fn {_level_num, level_name, domain, payload} ->
        (is_nil(expected_level) or level_name == expected_level) and
          (is_nil(expected_domain) or domain == expected_domain) and
          (is_nil(expected_data) or map_subset?(payload, expected_data))
      end)

    assert match?, "no client log matched #{inspect(opts)}.\nLogs: #{inspect(logs)}"
    logs
  end

  @doc "Refute that any client log was emitted."
  def refute_client_log_seen do
    logs = drain_logs()
    assert logs == [], "expected no client logs, got: #{inspect(logs)}"
    :ok
  end

  defp extract_text(result) do
    case result do
      %{content: [%{type: :text, text: text} | _]} -> text
      %{contents: [%{text: text} | _]} -> text
      %{text: text} -> text
      other -> flunk("expected text content, got: #{inspect(other)}")
    end
  end

  defp resource_text({:ok, _uri, content}), do: resource_text(content)
  defp resource_text(%{text: text}) when is_binary(text), do: text
  defp resource_text(%{"text" => text}) when is_binary(text), do: text
  defp resource_text(%{contents: [%{text: text} | _]}), do: text
  defp resource_text(other), do: flunk("expected resource text content, got: #{inspect(other)}")

  defp assert_content_type(result, type, opts) do
    case result do
      %{content: [%{type: ^type} = item | _]} ->
        match_attrs(item, opts, "#{type} content")
        item

      other ->
        flunk("expected #{type} tool response, got: #{inspect(other)}")
    end
  end

  defp match_attrs(item, opts, label) do
    Enum.each(opts, fn {key, expected} ->
      actual = Map.get(item, key) || Map.get(item, to_string(key))

      assert match_value?(actual, expected),
             "#{label}: #{inspect(key)} expected #{inspect(expected)}, got #{inspect(actual)}"
    end)
  end

  defp match_value?(actual, %Regex{} = re) when is_binary(actual), do: actual =~ re
  defp match_value?(actual, expected), do: actual == expected

  defp text_matches?(actual, expected) when is_binary(actual) and is_binary(expected),
    do: actual == expected

  defp text_matches?(actual, %Regex{} = re) when is_binary(actual), do: actual =~ re
  defp text_matches?(_, _), do: false

  defp assert_match(actual, %Regex{} = re, label) do
    assert is_binary(actual) and actual =~ re,
           "#{label}: expected to match #{inspect(re)}, got #{inspect(actual)}"
  end

  defp assert_match(actual, expected, label) do
    assert actual == expected,
           "#{label}: expected #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp drain(tag), do: drain(tag, [])

  defp drain(tag, acc) do
    receive do
      {^tag, payload} -> drain(tag, [payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_logs(acc \\ []) do
    receive do
      {:phantom_test_client_log, level, level_name, domain, payload} ->
        drain_logs([{level, level_name, domain, payload} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp map_subset?(superset, subset) when is_map(superset) and is_map(subset) do
    Enum.all?(subset, fn {k, v} ->
      actual = Map.get(superset, k) || Map.get(superset, to_string(k))
      actual == v
    end)
  end

  defp map_subset?(_, _), do: false
end

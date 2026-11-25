# Testing

`Phantom.Test` drives your router's handlers directly, without an HTTP
transport. Each dispatcher blocks until the final response, so the same test
works whether the handler answered synchronously (`{:reply, _, _}`) or
asynchronously (`{:noreply, _}` with `Phantom.Session.respond/2`).

## Setup

Register the router with `Phantom.Test.start/1` and build a session with
`Phantom.Test.build_session/2`:

```elixir
defmodule MyApp.MCP.RouterTest do
  use ExUnit.Case, async: true
  import Phantom.Test

  setup do
    Phantom.Test.start(router: MyApp.MCP.Router)
    {:ok, session: build_session(MyApp.MCP.Router, assigns: %{user: user_fixture()})}
  end
end
```

`build_session/2` takes the same allow-lists you set in
`c:Phantom.Router.connect/2`, such as `:allowed_tools`, so you can test what a
limited session sees. Pass `protocol_version: "2026-07-28"` to test the
stateless protocol.

## Tools, prompts, and resources

```elixir
test "creates a question", %{session: session} do
  session
  |> call_tool(:create_question, %{study_id: 1, label: "Why?", description: "…"})
  |> assert_tool_resource_link()
end

test "reviews a study", %{session: session} do
  session
  |> get_prompt(:suggest_questions, %{study_id: 1})
  |> assert_prompt_message(role: :user, text: ~r/Wowzers/)
end

test "reads a study", %{session: session} do
  session
  |> read_resource(:study, study_id: 1)
  |> assert_resource_text(~r/# Study/)
end

test "rejects missing arguments", %{session: session} do
  session
  |> call_tool(:create_question, %{})
  |> assert_jsonrpc_error(code: -32602)
end
```

See `Phantom.Test` for every assertion, such as `assert_tool_error/2`,
`assert_tool_image/2`, and `assert_resource_blob/2`.

## Elicitation

Answer elicitations with `Phantom.Test.expect_elicit/1`:

```elixir
test "greets the user by name", %{session: session} do
  expect_elicit(fn _elicit ->
    {:ok, %{"action" => "accept", "content" => %{"name" => "Joe"}}}
  end)

  session
  |> call_tool(:greet, %{})
  |> assert_tool_text(~r/Joe/)
end
```

## Progress and logs

`assert_progress_seen/1` and `assert_client_log_seen/1` assert on the
notifications a handler sent, without PubSub. Features that need PubSub,
such as resource subscriptions and list-changed notifications across nodes,
are opt-in:

```elixir
Phantom.Test.start(router: MyApp.MCP.Router, pubsub: MyApp.PubSub)
```

## Over HTTP

To test the transport itself, such as authentication in
`c:Phantom.Router.connect/2`, send requests through your endpoint with
`Plug.Test` or `Phoenix.ConnTest`, or point the
[MCP Inspector](https://modelcontextprotocol.io/docs/tools/inspector) at a
running server.

Skills and A2A agents have testing sections in their own guides:
[Skills](skills.md#testing) and [A2A](a2a.md#testing).

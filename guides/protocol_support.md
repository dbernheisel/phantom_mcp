# Protocol Support

Phantom serves the [MCP specification](https://modelcontextprotocol.io/specification)
over Streamable HTTP and stdio, from session-based legacy versions through the
stateless `2026-07-28` core. It negotiates the version each client asks for;
one router serves them all.

## Methods Phantom implements

Phantom implements these MCP requests on your behalf:

- `initialize`. Phantom detects what capabilities are available to the client
  based on the tooling defined in your router.
- `ping` answers with an empty result.
- `tools/list` lists the allowed tools as provided in
  `c:Phantom.Router.connect/2`, or all tools by default. To disable, return
  `allow_tools(session, [])` in `connect/2`.
- `tools/call` dispatches the request to your handler. See [Tools](tools.md).
- `prompts/list` lists the allowed prompts, or all prompts by default. To
  disable, return `allow_prompts(session, [])` in `connect/2`.
- `prompts/get` dispatches the request to your handler if allowed. See
  [Prompts](prompts.md).
- `resources/list` dispatches to `c:Phantom.Router.list_resources/2`. It is an
  empty list until you implement it. See [Resources](resources.md).
- `resources/templates/list` lists the allowed resource templates, or all of
  them by default. To disable, return `allow_resource_templates(session, [])`
  in `connect/2`.
- `resources/read` dispatches the request to your handler.
- `resources/subscribe` and `resources/unsubscribe` are available if the
  router is configured with `pubsub`. See
  [Resources](resources.md#subscriptions).
- `completion/complete` dispatches the request to the completion function for
  the given prompt or resource template.
- `logging/setLevel` is available if the router is configured with `pubsub`.
  Send logs to the client with `Phantom.ClientLogger`, such as
  `Phantom.ClientLogger.info(session, %{message: "Indexing"}, "search")`; see
  [log levels](https://modelcontextprotocol.io/specification/2025-03-26/server/utilities/logging#log-levels).
- `elicitation/create` requests input from the client to complete a request
  it made. Under `2026-07-28` the server-initiated SSE push is replaced by an
  `input_required` result and encrypted `requestState`; both go through
  `Phantom.Session.elicit/3` and behave identically from the handler's point
  of view. See [Elicitation](elicitation.md).
- `notifications/*` from the client are no-ops.

Phantom sends these notifications:

- `notifications/tools/list_changed` when `Phantom.Cache.add_tool/2` is called.
- `notifications/prompts/list_changed` when `Phantom.Cache.add_prompt/2` is
  called.
- `notifications/resources/list_changed` when you call
  `Phantom.Tracker.notify_resource_list/0`. This is not automatic; be mindful
  of what resources each session may access.
- `notifications/resources/updated` when you call
  `Phantom.Tracker.notify_resources_updated/1` for subscribed resources.

## Extensions

- [Tasks](tasks.md): `tasks/get`, `tasks/update`, and `tasks/cancel` under
  `2026-07-28`, when the router implements `c:Phantom.Router.get_task/2`.
- [Skills](skills.md): `skills/list`, `skills/get`, and
  `resources/directory/read`.
- [MCP Apps](mcp_apps.md): interactive HTML interfaces rendered by the host.
- [OAuth Client Credentials](oauth_client_credentials.md): machine clients
  with no user present.

## Not yet supported

- `roots/list`, where the server asks the client for the files available for
  interaction. This is like `resources/list` but for the client.
- `sampling/createMessage`, where the server asks the client to query its LLM
  and return the response.
- Resuming a broken SSE stream with the `last-event-id` header.

## Batched requests

Batched JSON-RPC requests are handled transparently. There is no abstraction
for providing them to your handler as a group; since the MCP specification
deprecated batching, there is no plan to make this more efficient.

## A2A

The same router can also serve [A2A](https://a2a-protocol.org) agents. See
the [A2A](a2a.md) guide.

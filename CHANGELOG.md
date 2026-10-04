## Unreleased

- New: `Phantom.Test` for unit-testing MCP routers without an HTTP transport.
  `build_session(router, protocol_version: "2026-07-28")` tests the stateless
  protocol; `expect_elicit/1` answers its `input_required` results.
- New: `c:Phantom.Router.authorize_resource_subscriptions/2` authorizes
  resource subscriptions (`resources/subscribe` and `subscriptions/listen`)
  and is re-checked before each update notification. Resources are allowed by
  default.
- New: `Phantom.Tracker.notify_resources_updated/1` notifies a batch of
  updated resources with one authorization call per subscribed session.
- New: `Phantom.Prompt.input_required/1`. Prompt handlers can return an
  `input_required` result under MCP 2026-07-28.
- Session messages reach the session's stream on any node immediately.
  `logging/setLevel`, `resources/subscribe`, `resources/unsubscribe`, and
  client logs used to fail or be lost when they reached a node before
  `Phantom.Tracker` had replicated the session from another node; they now
  go through a per-session PubSub topic in that case.
- `logging/setLevel` replies once the level is applied, and no longer writes
  an empty `{}` event to the session stream.
- An HTTP `DELETE` closes the session's open streams on every node; it
  previously only untracked streams on the node that received it.
- The `initialize` response stream closes after the response, as the spec
  recommends. Server-initiated messages (notifications, logs, resource
  updates) go to the session's GET stream; clients that never open one no
  longer receive them on the `initialize` stream. A client's GET stream no
  longer gets 409 because the `initialize` stream held the session.
- New: `Phantom.Plug` `:hosts` option rejects requests whose `Host` header is
  not allowed (403), protecting servers bound to localhost from DNS
  rebinding. Defaults to `:all`.
- Origin validation accepts requests without an `Origin` header. Only
  browsers send one, so validation previously rejected every non-browser
  client unless it was turned off.
- Map-based `input_schema` and `output_schema` reach clients as given, so
  `$schema`, `$defs`, `$ref`, `allOf`, `if`/`then`/`else`,
  `additionalProperties`, and other JSON Schema keywords are kept. They
  previously raised at compile time or were dropped.
- `Session.elicit/3` re-entry passes the accepted content to the resumed
  handler under every protocol version. Before 2026-07-28 it passed the whole
  client response, so resume clauses never matched and the handler asked the
  user again indefinitely.
- Elicitation enums keep their `default`, and titled multi-select enums use
  `items.anyOf` as the spec requires (was `items.oneOf`, which clients
  rejected).
- New: `connect/2` may return `{:not_found | 404, message}` to answer with
  HTTP 404. Record terminated sessions in `terminate/1` and reject them this
  way, as the MCP spec requires 404 for a terminated session ID.
- Resource URIs keep their host. `resource "https://example.com/x/:id", ...`
  now advertises `https://example.com/x/{id}` and `resource_uri/3` builds
  `https://example.com/x/1` (both previously dropped the host), and only
  URIs with that host match it (previously any host did). Host-only URIs
  such as `myapp://settings` can now be defined, and reading an unknown one
  returns "Resource not found" instead of crashing.
- MCP 2026-07-28 fixes found by the conformance suite:
  - -32021 errors name `requiredCapabilities` as a ClientCapabilities object
    and are sent with HTTP status 400.
  - A `MCP-Protocol-Version` header that disagrees with `_meta` is a -32020
    header mismatch, checked before the -32022 unsupported version.
  - Whitespace around `Mcp-*` header values is ignored, and a value is only
    decoded as Base64 when it has both the `=?base64?` prefix and `?=` suffix.
- Initial support for MCP 2026-07-28 stateless core. `Phantom.Session.elicit/3`
  uses true stateless re-entry: the handler returns
  `{:noreply, Session.elicit(session, elicit, state: %{...})}`, Phantom
  authenticates and encrypts that state into `requestState`, and any node can
  re-invoke the handler with `session.state` populated. Inline `await: true`,
  and `Session.elicit/3` from a process the handler started, work under both
  protocols: under stateless core the process waits on its node while the
  client answers an `input_required` result, and the follow-up call resumes it.
  - `Phantom.Tool.input_required/2` is the lower-level builder for
    constructing an `input_required` result map directly (skipping Task
    suspension).
  - Existing legacy code that called `Session.elicit/3` without opts
    continues to work unchanged — the default under legacy is still inline
    blocking.
- Tools/call now always dispatches in a spawned Task. Tool crashes are
  isolated to the Task (the HTTP/session process keeps serving) and
  surface via the `[:phantom, :dispatch, :exception]` telemetry event.
- New: `Phantom.Session.respond_error/3` finalizes a pending request with
  a JSON-RPC error from an async task.
- New: `Phantom.Router` accepts `:secret_key_base` and `:request_state_salt`
  for the encrypted `requestState` codec. Both required when supporting
  MCP `2026-07-28`.
- New: `Phantom.RequestState` (Plug.Crypto-backed encode/decode of the
  continuation blob) and `Phantom.Session.stateless?/1` predicate.
- New: `Phantom.Request.with_cache/2` annotates any result with `ttlMs` /
  `cacheScope`.
- W3C trace context (`traceparent` / `tracestate` / `baggage`) from `_meta`
  is automatically surfaced on the `[:phantom, :dispatch]` telemetry span
  under `metadata.trace_context`. Wire your tracer to that event (see
  "Distributed tracing" in the README).
- MCP `2026-07-28` adds three optional headers — `mcp-protocol-version`,
  `mcp-method`, `mcp-name` — that upstream infrastructure (load balancers,
  WAFs, gateways) can route on without inspecting the JSON-RPC body.
  Phantom passes them through; no server-side configuration needed.

### For existing users

**If you only target legacy MCP clients (≤ 2025-11-25):** your existing
code works unchanged. No changes required. The protocol-aware default for
`Session.elicit/3` preserves the historical inline-blocking behavior on
legacy.

```elixir
# Existing handler — unchanged, still works.
def my_tool(params, session) do
  case Session.elicit(session, @elicit_name) do
    {:ok, %{"action" => "accept", "content" => content}} ->
      {:reply, Tool.text("Hello \#{content["name"]}"), session}

    {:ok, _rejected} ->
      {:reply, Tool.error("Rejected"), session}

    :not_supported ->
      {:reply, Tool.text("Hello stranger"), session}
  end
end
```

**If you want to also support modern MCP `2026-07-28` clients:**

*Step 1.* Add `:secret_key_base` and `:request_state_salt` to your router.
Phantom encrypts the multi-round-trip `requestState` blob with `Plug.Crypto`;
nodes serving the same router must share both values.

```elixir
use Phantom.Router,
  name: "MyApp",
  vsn: "1.0",
  secret_key_base: Application.compile_env(:my_app, :secret_key_base),
  request_state_salt: "myapp request_state v1"
```

- `:secret_key_base` is a high-entropy binary ≥ 64 bytes. Generate one with
  `:crypto.strong_rand_bytes(64) |> Base.encode64()`.
- `:request_state_salt` is a stable string of your choosing — it's the HKDF
  salt used to derive a key specifically for requestState blobs. Doesn't
  need to be secret, but rotating it invalidates all in-flight blobs.

The router raises at compile time if the key is too short, if one is set
without the other, and warns if both are missing while tools or prompts
are defined.

*Step 2.* Pick a migration shape for your `Session.elicit/3` calls.
Existing calls without `:await` work under legacy because legacy defaults
to inline blocking, but the same call under `2026-07-28` would return the
re-entry tagged tuple instead — which your existing `case {:ok, _}`
clauses don't match.

The smallest change is to add `await: true` everywhere you currently call
`Session.elicit/3` for blocking behavior:

```elixir
# Before: implicit inline blocking, legacy-only
{:ok, response} = Session.elicit(session, elicit)

# After: explicit inline blocking, under either protocol
{:ok, response} = Session.elicit(session, elicit, await: true)
```

Under `2026-07-28`, `await: true` keeps the process waiting on its node
until the client's follow-up call; re-entry (below) keeps nothing in memory.

### Recommendation for new PhantomMCP users targeting modern MCP clients

For greenfield code, use the **re-entry pattern** rather than `await: true`.
Re-entry is the natural shape for stateless: the handler is invoked again
with `session.state` populated, no suspended Task, no `Phantom.Tracker`
required for cross-node routing.

```elixir
use Phantom.Router,
  name: "MyApp",
  vsn: "1.0",
  secret_key_base: Application.compile_env(:my_app, :secret_key_base)

tool :delete_file do
  field :path, :string, required: true
end

# Resume clause — runs on the second invocation.
def delete_file(
      %{"confirm" => "yes"},
      %Phantom.Session{state: %{step: :confirming, path: path}} = session
    ) do
  File.rm!(path)
  {:reply, Tool.text("Deleted \#{path}"), session}
end

def delete_file(%{"confirm" => _}, session),
  do: {:reply, Tool.text("Cancelled"), session}

# First-call clause — ask the client.
def delete_file(%{"path" => path}, session) do
  {:noreply,
   Phantom.Session.elicit(
     session,
     Phantom.Elicit.form(%{
       message: "Really delete \#{path}?",
       requested_schema: [
         %{name: "confirm", type: :enum, enum: ["yes", "no"], required: true}
       ]
     }),
     state: %{step: :confirming, path: path}
   )}
end
```

Why re-entry over inline `await: true`:

- **Truly stateless on the wire** — `state` is encrypted into `requestState`
  and travels with the client. Any node can serve any follow-up call, and a
  node restart loses nothing; an inline `await: true` waits in a process that
  a restart or `:timeout` ends.
- **No resource pinning** — re-entry has no in-memory state between requests.
- **Pattern-match clarity** — the resume clause is a function head, not a
  `case` block buried in the middle of a function.
- **Multi-step state machines** read naturally — each step is its own
  re-entry clause matching on a different `step` atom.

Reserve `await: true` for cases where the inline ergonomics are
genuinely simpler (short interactions, no multi-step flow, no need for
distribution beyond one node).

## 0.5.3 (2026-09-04)

- Switch UUID dependency from `uuidv7` to `uuid_v7` to avoid module name
  collisions with other Hex packages that also define `UUIDv7` (e.g. when used
  alongside `posthog`). Call sites are unchanged (`UUIDv7.generate/0`).

## 0.5.2 (2026-08-20)

- Remove `Connection: keep-alive` in response headers in SSE stream. This is
handled in other infrastructure. (thanks @merhard)
- Omit `nextCursor` in pagination responses if there are no more. Simply the
presence, even if null, can trip up clients. (thanks @merhard)
- Allow standalone `Phantom.Tool.JSONSchema` modules. (thanks @merhard)

## 0.5.1 (2026-08-11)

- Fix Resource subscriptions' responses when they have empty responses. (thanks
  @merhard)

## 0.5.0 (2026-07-27)

- Add `Phantom.App` which represents a Plug for mounting MCP Apps, which are
embedded and self-contained resources in desktop clients.
- Fix 202 response for SSE connections for notifications (thanks @anagrius)

## 0.4.5 (2026-04-29)

- Fix `Plug.Conn.AlreadySentError` when a second SSE GET arrives for an
  existing session. The conflict response (`409 -32000`) is now returned
  cleanly without attempting to write streaming headers on the sent conn.

## 0.4.4 (2026-04-13)

- Defend from potential elicitation replication lag
- Track Elicitations to ensure duplicate requests are not sent

## 0.4.3 (2026-04-03)

- Fix invalid response when client request an invalid resource_uri

## 0.4.2 (2026-04-03)

- Elicitation requests can use the POSTs connection. This should fix hung-up elicitations.
- Phoenix.Tracker can take some time to replicate, so add retries when session metadata is not available
- Improve cross-nodes tests

## 0.4.1 (2026-04-02)

- Add additional Logging when dispatching requests to unalive PIDs
- Catch exits due to calling unalive PIDs (thanks @davydog187)
- Fix Phantom.Tracker
- Fixup dialyzer specs
- Providing nil to binary response content (eg, image, audio) will now raise instead of encoding `<<>>`.

## 0.4.0 (2026-03-27)

- Add `Phantom.Stdio` adapter for local-only clients (e.g. Claude Desktop).
  Add `{Phantom.Stdio, router: MyApp.MCP.Router}` to your supervision tree.
  See `Phantom.Stdio` for more details.
- Add `Phantom.Icon` support for server info, tools, and prompts per MCP
  2025-11-25 specification. Icons can be set at the router level with
  `use Phantom.Router, icons: [...]` or per-tool/prompt.
- Server now declares support for MCP spec `2025-11-25`.
- Elicitation support is fully implemented. `Phantom.Session.elicit/3` now
  blocks until the client responds (with configurable timeout) and works
  across both HTTP and stdio transports. See `Phantom.Elicit`.
- `Phantom.Tracker` now works without `phoenix_pubsub` for stdio transport,
  falling back to process dictionary for session metadata.
- Fixed bugs with rendering embedded_resources
- New tool DSL with `do` block to provide input schemas using an
  Ecto.Schema-like syntax. For example, before you had to manually write
  the JSONSchema input schema:

  ```elixir
  tool :validated_echo_tool,
    description: "Echo with validation",
    input_schema: %{
      required: ~w[message],
      properties: %{
        message: %{type: "string", description: "Foo bar"},
        count: %{type: "integer", description: "Foo bar"},
        tags: %{type: "array", items: %{type: :string}, description: "Foo bar"}
      }
    }
  ```

  But now you can declare it with a `do` block:

  ```elixir
  tool :validated_echo_tool, description: "Echo with validation" do
    field :message, :string, required: true, description: "Foo bar"
    field :count, :integer, default: 1, description: "Foo bar"
    field :tags, {:array, :string}, description: "Foo bar"
  end
  ```

  The `do` block also supports nested maps, custom validators, and all
  JSON Schema types. The old map-based `input_schema` syntax continues
  to work. See `Phantom.Tool.JSONSchema` for more info.

## 0.3.4 (2026-02-24)

- **Breaking** When using `Phantom.Plug`, pass the `conn` to the router connect
  callback instead of a map with params and headers keys. Upgrade and make this
  adjustment in your connect callback:

  ```elixir
  # Before
  def connect(session, context) do
    %{params: params, headers: headers} = context
    # ...
  end

  # After
  def connect(session, conn) do
    %{query_params: params, req_headers: headers} = conn
    # ...
  end
  ```

## 0.3.3 (2026-02-22)

- Fixup Cache key mismatch
- Fixup updating state in async returns
- Fixup running without `phoenix_pubsub`

## 0.3.2 (2025-07-04)

- Fix error message referring to wrong arity.
- Allow nil origin when Plug options is set to `origins: :all`.
- Better error handling when `Phantom.Tracker` is not in the supervision tree. Phantom.MCP will now emit a Logger warning when Phantom.Tracker can be used, but is not in the supervision tree.
- Fix terminate bug introduced in 0.3.1

## 0.3.1 (2025-07-03)

- Add `[:phantom, :plug, :request, :terminate]` telemetry event.
- Improve docs

## 0.3.0 (2025-06-29)

- Move logging functions from `Phantom.Session` into `Phantom.ClientLogger`.
- Rename `Phantom.Tracker` functions to be clearer and more straightforward.
- Consolidate distributed logic into `Phantom.Tracker` such as PubSub topics.
- Add ability to add tools, prompts, resources in runtime easily. You can call
  `Phantom.Cache.add_tool(router_module, tool_spec)`. The spec can be built with
  `Phantom.Tool.build/1`, the function takes a very similar shape to the corresponding macro from `Phantom.MCP.Router`. This will also trigger notifications to clients of tool or prompt list updates.
- Handle paginatin for 100+ tools and prompts.
- Change `connect/2` callback to receive request headers and query params from the Plug adapter. The signature is now `%{headers: list({header, value}), params: map()}` where before it was just `list({header, value})`.
- `Phantom.Tool.build`, `Phantom.Prompt.build` and `Phantom.ResourceTemplate.build` now do more and the `Phantom.Router` macros do less. This is so runtime can have a consistent experience with compiled declarations. For example, you may `Phantom.ResourceTemplate.build(...)` with the same arguments as you would with the router macros, and then call `Phantom.Cache.add_resource_template(...)` and have the same affect as using the `resource ...` macro in a `Phantom.Router` router.
- Fixed building tool annontations.
- Fixed resource subscription response and implemented unsubscribe method.
- Improve documentation

## 0.2.3 (2025-06-24)

- Fix the `initialize` request status code and headers. In 0.2.2 it worked
with mcp-inspector but not with Claude Desktop or Zed. Now it works with all.

## 0.2.2 (2025-06-22)

- Fix the `initialize` request. It should have kept the SSE stream open.
- Fix bugs

## 0.2.1 (2025-06-21)

- Fix default `list_resources/2` callback and default implementation.

## 0.2.0 (2025-06-17)

Phantom MCP released!

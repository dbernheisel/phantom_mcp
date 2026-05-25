## Unreleased

- Initial support for MCP 2026-07-28 stateless core. `Phantom.Session.elicit/3`
  has two call patterns with protocol-aware defaults:
    - **Inline blocking** (`await: true`, or default under legacy) — the
      handler continues after the response arrives. Under stateless, the
      tool's Task is suspended and resumed inline when the follow-up
      `tools/call` arrives, possibly on a different node.
    - **Re-entry** (`:state` set, or default under stateless) — returns
      `{:input_required, elicit, state, session}`; the dispatcher converts
      that to `inputRequired` (stateless) or an SSE elicit round-trip
      (legacy). The handler is re-entered with `session.state` populated to
      whatever you passed as `:state`.
  - `Phantom.Tool.input_required/1` is the lower-level result builder.
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

# After: explicit inline blocking, works on both protocols
{:ok, response} = Session.elicit(session, elicit, await: true)
```

Under `2026-07-28`, `await: true` suspends the tool's Task and resumes it
inline when the follow-up `tools/call` arrives (possibly on a different
node). The handler reads the same.

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
  Phantom.Session.elicit(
    session,
    Phantom.Elicit.form(%{
      message: "Really delete \#{path}?",
      requested_schema: [
        %{name: "confirm", type: :enum, enum: ["yes", "no"], required: true}
      ]
    }),
    state: %{step: :confirming, path: path}
  )
end
```

Why re-entry over inline `await: true`:

- **Truly stateless on the wire** — `state` is encrypted into `requestState`
  and travels with the client. Any node can serve any follow-up call.
  Inline `await: true` keeps a Task suspended on the originating node and
  uses `Phantom.Tracker` for cross-node delivery.
- **No resource pinning** — re-entry has no in-memory state between
  requests. Inline await holds an Erlang process per pending elicit (with
  a 5-minute default timeout).
- **Pattern-match clarity** — the resume clause is a function head, not a
  `case` block buried in the middle of a function.
- **Multi-step state machines** read naturally — each step is its own
  re-entry clause matching on a different `step` atom.

Reserve `await: true` for cases where the inline ergonomics are
genuinely simpler (short interactions, no multi-step flow, no need for
distribution beyond one node).

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

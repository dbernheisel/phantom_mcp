# Deployment

Phantom is designed to run behind a load balancer and across a cluster. The
shape of that deployment depends on which MCP protocol versions you serve:

| Client protocol | Sticky session required? | What the LB needs to do |
|---|---|---|
| `≤ 2025-11-25` (legacy) | Yes, *or* run `Phantom.Tracker` for cross-node routing | Hash on `mcp-session-id` header, OR enable cross-node session routing via `Phoenix.PubSub` |
| `2026-07-28` (stateless core) | No | Plain round-robin |

You can serve both from the same router; the load balancer just needs to
handle the legacy case correctly.

## Persistent streams

> Under MCP `2026-07-28` (stateless core), persistent SSE streams and
> `mcp-session-id` are gone: every request is self-contained and any node
> can serve any call. This section applies to clients on earlier protocol
> versions; you can run both side-by-side from the same router.

MCP defines a "Streamable HTTP" transport: typical HTTP and SSE connections
with a certain behavior. A legacy client will typically have multiple
connections:

1. `POST` for every command, such as `tools/call` or `resources/read`.
   Phantom opens an SSE stream and closes the connection once work has
   completed.
2. `GET` to start an SSE stream for events such as logs and notifications.
   There is no work to complete with these requests; it is a "channel" for
   receiving server requests and notifications. The connection remains open
   until either the client or server closes it.

All connections may provide an `mcp-session-id` header to resume a session.

Resource subscriptions, logging, and list-changed notifications need these
streams. To support them, Phantom tracks connection pids in your cluster with
`Phoenix.Tracker` (`phoenix_pubsub`). Start `Phantom.Tracker` and pass your
PubSub to `Phantom.Plug`:

```elixir
# Add to your application supervision tree:
{Phoenix.PubSub, name: MyApp.PubSub},
{Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: MyApp.PubSub]},
```

<!-- tabs-open -->

### Phoenix

```elixir
forward "/", Phantom.Plug,
  router: MyApp.MCP.Router,
  pubsub: MyApp.PubSub
```

### Plug.Router

```elixir
forward "/mcp", to: Phantom.Plug, init_opts: [
  router: MyApp.MCP.Router,
  pubsub: MyApp.PubSub
]
```

<!-- tabs-close -->

**Not yet supported** is resuming broken connections with missed messages
with the `last-event-id` header.

## Load balancers

### Sticky sessions for legacy clients

Route by the `mcp-session-id` request header. The header is present on every
legacy `POST` after `initialize`, and on the persistent SSE `GET` stream.

Nginx:

```nginx
upstream phantom_mcp {
  hash $http_mcp_session_id consistent;
  server app1.internal:4000;
  server app2.internal:4000;
}
```

HAProxy:

```
backend phantom_mcp
  balance hdr(mcp-session-id)
  server app1 app1.internal:4000 check
  server app2 app2.internal:4000 check
```

**If you can't configure header-based hashing** (cloud load balancers without
L7 hashing, for example), run `Phantom.Tracker` and `Phoenix.PubSub` as in
[Persistent streams](#persistent-streams). Any node can then route
session-bound traffic to the owning node internally.

### Stateless clients need no configuration

Under MCP `2026-07-28`, every request is self-contained. The encrypted
`requestState` blob carries continuation state across requests; any node
that shares `:secret_key_base` and `:request_state_salt` can serve any
request (see [Elicitation](elicitation.md#encrypting-request-state)). Use
round-robin or least-connections; sticky routing is wasted complexity.

### L7 routing with MCP `2026-07-28` headers

SEP-2243 requires clients on `2026-07-28` to mirror routing fields from the
JSON-RPC body into HTTP headers, so load balancers, proxies, and WAFs can
route on the operation without parsing the body:

- `Mcp-Method` mirrors `method`. Required on every `POST`.
- `Mcp-Name` mirrors `params.name` (for `tools/call`, `prompts/get`),
  `params.uri` (for `resources/read`), or `params.taskId` (for `tasks/get`,
  `tasks/update`, `tasks/cancel`). Route on it when tasks live in one node's
  memory.

Header names are case-insensitive; values are case-sensitive (so
`Mcp-Method: TOOLS/CALL` does *not* match a body method of `tools/call`).

Phantom validates these server-side and rejects requests where the headers
and body disagree, or where required headers are missing, with HTTP
`400 Bad Request` and JSON-RPC error code `-32001 HeaderMismatch`. Legacy
clients negotiating an older protocol version are exempt.

### Origin validation behind a proxy

By default `Phantom.Plug` validates the `Origin` header against the
configured `:origins` allowlist. Behind a TLS-terminating proxy, the
forwarded request still carries the original `Origin`; no extra config is
needed. If your proxy strips `Origin`, restore it before Phantom runs.

### Health checks

`Phantom.Plug` doesn't expose a dedicated health endpoint. Either:

- Have your load balancer `GET` a separate path (e.g. `/health`) defined in
  your app's main router, *not* forwarded to `Phantom.Plug`.
- Or send a JSON-RPC `ping` request to `/mcp`; Phantom handles `ping`
  natively.

## Response caching

When a handler annotates its result with `Phantom.Request.with_cache/2`, the
response gains top-level `ttlMs` and `cacheScope` fields modeled on HTTP
`Cache-Control`.

| Annotation | Reverse proxy / CDN behavior |
|---|---|
| `cacheScope: "public", ttlMs: 60_000` | Cache and serve to any user for 60s |
| `cacheScope: "private", ttlMs: 60_000` | Client-local cache only; shared caches must pass through |

Phantom doesn't translate `ttlMs` and `cacheScope` into HTTP `Cache-Control`
response headers; they ride in the JSON result for MCP-aware clients. For
HTTP-level caching, configure your proxy to translate them (for Nginx, a
small Lua snippet with OpenResty reading `result.ttlMs` and
`result.cacheScope`), or wrap `Phantom.Plug` in another Plug that mirrors the
values into headers.

> #### Public caching leaks user data {: .warning}
>
> Marking a user-specific response `"public"` lets one user's result be
> served to another from a shared cache. Omit the hints unless you're sure
> the result is the same for every user who may request it.

## Distributed tracing

Under MCP `2026-07-28`, clients carry W3C Trace Context (`traceparent`,
`tracestate`, and `baggage`) in the request's `_meta`. Phantom extracts these
and surfaces them on the `[:phantom, :dispatch]` telemetry span under
`metadata.trace_context`. Wire your tracer to the event.

Example with OpenTelemetry:

```elixir
# In your application's start callback:
:telemetry.attach(
  "phantom-otel-dispatch",
  [:phantom, :dispatch, :start],
  &MyApp.Telemetry.handle_dispatch/4,
  nil
)

defmodule MyApp.Telemetry do
  def handle_dispatch(_event, _measurements, %{method: method, trace_context: ctx}, _config) do
    # Extract the upstream W3C trace context into OpenTelemetry's process state
    :otel_propagator_text_map.extract(Enum.map(ctx, fn {k, v} -> {Atom.to_string(k), v} end))

    # Start a child span for this dispatch
    OpenTelemetry.Tracer.start_span("mcp:#{method}")
  end
end
```

For other tracers, the pattern is the same: attach to
`[:phantom, :dispatch, :start]` and read `metadata.trace_context`, a map with
`:traceparent`, `:tracestate`, and `:baggage` keys (only the ones present in
the request are included).

For every telemetry event, see `m:Phantom.Plug#module-telemetry` and
`m:Phantom.Router#module-telemetry`.

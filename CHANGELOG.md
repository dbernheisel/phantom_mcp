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

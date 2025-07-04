## 0.3.2

- Fix error message referring to wrong arity.

## 0.3.1

- Add `[:phantom, :plug, :request, :terminate]` telemetry event.
- Improve docs

## 0.3.0

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

## 0.2.3

- Fix the `initialize` request status code and headers. In 0.2.2 it worked
with mcp-inspector but not with Claude Desktop or Zed. Now it works with all.

## 0.2.2

- Fix the `initialize` request. It should have kept the SSE stream open.
- Fix bugs

## 0.2.1

- Fix default `list_resources/2` callback and default implementation.

## 0.2.0

Phantom MCP released!

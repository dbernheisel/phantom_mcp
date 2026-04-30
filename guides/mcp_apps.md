# Building MCP Apps

MCP Apps are interactive HTML interfaces delivered by your MCP server and
rendered inside host applications (Claude Desktop, Cursor, etc.) as
sandboxed iframes. The server provides the HTML; the host provides the
sandbox, theming, and communication bridge.

This guide walks through building an MCP App with Phantom, from the
Elixir server side through the JavaScript client and into production.

For the full client-side API reference, see the official
[MCP Apps specification](https://apps.extensions.modelcontextprotocol.io/).

## How it works

```
MCP Host (Claude Desktop, etc.)
  |
  |-- tools/list --> sees tool with _meta.ui.resourceUri
  |-- tools/call --> invokes the tool, gets result
  |-- resources/read --> fetches the app HTML
  |
  +-- renders HTML in sandboxed iframe
        |
        +-- App JS connects via postMessage
        +-- receives tool input + result
        +-- can call server tools, list resources
```

1. Your MCP router defines a tool with `app: MyApp`
2. Phantom auto-registers a `ui://` resource for the app's HTML
3. The host calls the tool, then fetches and renders the HTML
4. The JavaScript in the HTML connects to the host via `postMessage`
5. The app receives tool input/results and can call back to the server

## Server side: defining the app

### The App module

An app module uses `Phantom.App` and implements `mount/2` and `render/1`.
It works like a Plug pipeline — you can add plugs for layouts, CSP, etc.

```elixir
defmodule MyApp.MCP.WeatherApp do
  use Phantom.App,
    permissions: [:clipboard_write],
    prefers_border: true

  use Phoenix.Component
  import Phoenix.Controller, only: [put_root_layout: 2, put_layout: 2]

  plug :put_root_layout, html: {MyApp.MCP.Layouts, :root}
  plug :put_layout, html: {MyApp.MCP.Layouts, :app}

  plug Phantom.App.CSP,
    connect_domains: ["https://api.weather.gov"]

  @impl Phantom.App
  def mount(_params, session) do
    {:ok, %{user: session.assigns[:user]}}
  end

  @impl Phantom.App
  def render(assigns) do
    ~H"""
    <div class="weather-app">
      <h1>Weather Dashboard</h1>
      <div id="forecast"></div>
    </div>
    """
  end
end
```

### Router registration

Register the app on a tool with the `app:` option:

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router, name: "MyApp", vsn: "1.0"

  @description "Show the weather dashboard"
  tool :weather, app: MyApp.MCP.WeatherApp

  def weather(%{"location" => location}, session) do
    forecast = MyApp.Weather.fetch(location)
    {:reply, Phantom.Tool.text(forecast), session}
  end
end
```

Phantom automatically creates a `ui:///weather` resource template that
serves the app's rendered HTML when the host requests it.

### Callbacks

- **`mount(params, session)`** — called before render. Return
  `{:ok, assigns}` to add data to the render assigns. `params` are the
  tool arguments; `session` is the MCP session with any state from
  `connect/2`.

- **`render(assigns)`** — return HTML as a binary, iodata, or HEEx
  template. The assigns include everything from `mount/2` plus
  `:session`, `:params`, and `:conn`.

## Client side: the JavaScript bridge

The rendered HTML must include JavaScript from the
[`@modelcontextprotocol/ext-apps`](https://www.npmjs.com/package/@modelcontextprotocol/ext-apps)
package. This handles the `postMessage` protocol between your app
and the host.

### Install

```bash
npm install @modelcontextprotocol/ext-apps
npm install --save-dev esbuild
```

### Entry point

Create `assets/js/mcp_app.js`:

```javascript
import {
  App,
  applyDocumentTheme,
  applyHostStyleVariables,
  applyHostFonts,
} from "@modelcontextprotocol/ext-apps";

const app = new App({ name: "my-app", version: "1.0.0" });

// Apply host theming when it changes
app.onhostcontextchanged = (ctx) => {
  if (ctx.theme) applyDocumentTheme(ctx.theme);
  if (ctx.styles?.variables) applyHostStyleVariables(ctx.styles.variables);
  if (ctx.styles?.css?.fonts) applyHostFonts(ctx.styles.css.fonts);
};

// Receive tool arguments from the host
app.ontoolinput = ({ arguments: args }) => {
  console.log("Tool input:", args);
  // Update your UI with the tool arguments
};

// Receive tool execution result from the host
app.ontoolresult = (result) => {
  console.log("Tool result:", result);
  // Update your UI with the result data
};

// Required: handle teardown when the host closes the app
app.onteardown = async () => ({});
app.onerror = console.error;

// Connect to the host — must be called after handlers are set
app.connect().then(() => {
  const ctx = app.getHostContext();
  if (ctx?.theme) applyDocumentTheme(ctx.theme);
  console.log("Connected to host:", app.getHostVersion());
});
```

The `App` class provides methods to call back to the MCP server
through the host:

```javascript
// Call a server tool
const result = await app.callServerTool({
  name: "get_forecast",
  arguments: { location: "NYC" }
});

// List server resources
const { resources } = await app.listServerResources();

// Read a server resource
const { contents } = await app.readServerResource({
  uri: "myapp:///data/123"
});

// Send a message to the host's conversation
await app.sendMessage({
  role: "user",
  content: [{ type: "text", text: "Show me the weekly forecast" }]
});
```

For the complete client API, see the
[MCP Apps SDK documentation](https://apps.extensions.modelcontextprotocol.io/specification/architecture).

For framework-specific starters (React, Vue, Svelte, Preact, Solid),
see the [ext-apps examples](https://github.com/modelcontextprotocol/ext-apps/tree/main/examples).

### Bundle for production

```bash
npx esbuild assets/js/mcp_app.js \
  --bundle --format=iife --minify \
  --tree-shaking=true --target=es2020 \
  --define:process.env.NODE_ENV=\"production\" \
  --outfile=priv/static/mcp_app.js
```

For Phoenix projects, integrate with your existing esbuild pipeline in
`config/config.exs` or add a mix alias.

## Layout: loading the JavaScript

The app HTML is delivered as a JSON string and injected into a sandboxed
iframe by the host. The JavaScript bundle **must** be base64-encoded and
loaded via a `data:` URI — inline `<script>` tags break because the
host's `document.write()` injection conflicts with backticks and template
literals in minified JavaScript.

```elixir
defmodule MyApp.MCP.Layouts do
  use Phoenix.Component

  @mcp_app_js_b64 "priv/static/mcp_app.js"
                   |> File.read!()
                   |> Base.encode64()

  def root(assigns) do
    assigns = assign(assigns, :mcp_app_js_b64, @mcp_app_js_b64)

    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8" />
      <script src={"data:text/javascript;base64,#{@mcp_app_js_b64}"}></script>
    </head>
    <body>{@inner_content}</body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <main style="max-width: 800px; margin: 0 auto; padding: 24px;">
      {@inner_content}
    </main>
    """
  end
end
```

## Content Security Policy

Use `Phantom.App.CSP` to declare which external domains your app needs
to contact. This sets the `Content-Security-Policy` header and provides
CSP metadata to the host for its sandbox configuration.

```elixir
plug Phantom.App.CSP,
  connect_domains: ["https://api.example.com", "wss://realtime.example.com"],
  resource_domains: ["https://cdn.example.com"],
  frame_domains: ["https://embed.example.com"]
```

See `Phantom.App.CSP` for all options.

## Visibility

Tools with an `app:` option control who can see and invoke them via the
`visibility` setting on the tool's `:ui` metadata:

- `"model"` — visible in `tools/list`, the LLM can call it
- `"app"` — callable by other MCP App UIs via `app.callServerTool()`

The default is `["model", "app"]`. Override with the `:ui` option:

```elixir
# App-only: hidden from the model, callable from other apps
tool :fetch_data, app: MyApp.DataApp,
  ui: [visibility: [:app]]

# Model-only: the model can call it but other apps cannot
tool :admin, app: MyApp.AdminApp,
  ui: [visibility: [:model]]
```

## Dev Preview

Mount `Phantom.App.Preview` to browse and test your apps in the browser
during development:

```elixir
# Phoenix Router
if Mix.env() == :dev do
  forward "/mcp-apps", Phantom.App.Preview,
    router: MyApp.MCP.Router,
    mcp_endpoint: "/mcp"
end
```

The `:mcp_endpoint` option connects the preview to your running MCP
server, so interactive features (calling tools, listing resources) work
end-to-end. Visit `/mcp-apps` to see registered apps and click one to
open it in a sandboxed preview with a resizable viewport.

See `Phantom.App.Preview` for details.

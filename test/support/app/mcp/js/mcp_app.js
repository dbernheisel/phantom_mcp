/**
 * MCP App client — initializes the postMessage connection with the host
 * and dispatches DOM events for inline scripts to consume.
 *
 * Loaded via the root layout's <script> tag.
 * Exposes `window.mcpApp` for direct access from app scripts.
 */

import {
  App,
  applyDocumentTheme,
  applyHostStyleVariables,
  applyHostFonts
} from "@modelcontextprotocol/ext-apps";

const app = new App({ name: "phantom-test-app", version: "1.0.0" });
window.mcpApp = app;

function dispatch(name, detail) {
  document.dispatchEvent(new CustomEvent(name, { detail }));
}

app.ontoolinput = (params) => {
  dispatch("mcp:tool-input", params);
};

app.ontoolinputpartial = (params) => {
  dispatch("mcp:tool-input-partial", params);
};

app.ontoolresult = (result) => {
  dispatch("mcp:tool-result", result);
};

app.ontoolcancelled = (params) => {
  dispatch("mcp:tool-cancelled", params);
};

app.onhostcontextchanged = (ctx) => {
  if (ctx.theme) applyDocumentTheme(ctx.theme);
  if (ctx.styles?.variables) applyHostStyleVariables(ctx.styles.variables);
  if (ctx.styles?.css?.fonts) applyHostFonts(ctx.styles.css.fonts);
  dispatch("mcp:host-context-changed", ctx);
};

app.onteardown = async () => {
  dispatch("mcp:teardown", {});
  return {};
};

app.onerror = console.error;

app.connect().then(() => {
  const ctx = app.getHostContext();
  if (ctx) {
    if (ctx.theme) applyDocumentTheme(ctx.theme);
    if (ctx.styles?.variables) applyHostStyleVariables(ctx.styles.variables);
    if (ctx.styles?.css?.fonts) applyHostFonts(ctx.styles.css.fonts);
  }
  dispatch("mcp:initialized", {
    hostContext: ctx,
    hostCapabilities: app.getHostCapabilities(),
    hostInfo: app.getHostVersion(),
  });
});

// --- Server-call helpers -----------------------------------------------
// The host advertises `serverTools`, `serverResources`, `serverPrompts`
// capabilities when the MCP server supports them (see preview.js). The
// App class exposes `callServerTool`, `listServerResources`, and
// `readServerResource` for proxying requests through the host's Client.
//
// These wrappers add event dispatch so inline <script> blocks can observe
// results without awaiting Promises directly.

async function callServerTool(name, args) {
  try {
    const result = await app.callServerTool({ name, arguments: args ?? {} });
    dispatch("mcp:server-tool-result", { name, arguments: args, result });
    return result;
  } catch (error) {
    dispatch("mcp:server-tool-error", { name, arguments: args, error: error.message });
    throw error;
  }
}

async function listServerResources(params) {
  try {
    const result = await app.listServerResources(params);
    dispatch("mcp:server-resources-list", { result });
    return result;
  } catch (error) {
    dispatch("mcp:server-resources-error", { error: error.message });
    throw error;
  }
}

async function readServerResource(uri) {
  try {
    const result = await app.readServerResource({ uri });
    dispatch("mcp:server-resource-read", { uri, result });
    return result;
  } catch (error) {
    dispatch("mcp:server-resource-error", { uri, error: error.message });
    throw error;
  }
}

window.mcpApp.callServerToolNamed = callServerTool;
window.mcpApp.listServerResourcesNamed = listServerResources;
window.mcpApp.readServerResourceNamed = readServerResource;

// Also allow DOM-event-driven invocation so inline scripts can stay
// decoupled from the bundle's module surface.
document.addEventListener("mcp:request-server-tool", (e) => {
  const { name, arguments: args } = e.detail ?? {};
  if (name) callServerTool(name, args).catch(() => {});
});

document.addEventListener("mcp:request-list-resources", (e) => {
  listServerResources(e.detail?.params).catch(() => {});
});

document.addEventListener("mcp:request-read-resource", (e) => {
  const uri = e.detail?.uri;
  if (uri) readServerResource(uri).catch(() => {});
});

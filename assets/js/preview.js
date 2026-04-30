/**
 * MCP App Preview Host — vanilla JS equivalent of @mcp-ui/client's
 * AppRenderer. Uses AppBridge + PostMessageTransport with a sandbox
 * proxy (per the mcp-ui walkthrough) to render MCP Apps in iframes.
 *
 * This runs on the preview page (the host side), NOT inside the app iframe.
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import {
  AppBridge,
  PostMessageTransport,
  UI_EXTENSION_CAPABILITIES,
} from "@mcp-ui/client";

var IMPLEMENTATION = { name: "phantom-preview", version: "1.0.0" };

// ---------------------------------------------------------------------------
// Client style presets
// ---------------------------------------------------------------------------

// Hand-ported from priv/static/claude-desktop.css. The CSS file is the
// reference document (copied from Claude Desktop itself); this object is
// what the JS actually consumes. Each --color-* var in the CSS uses
// `light-dark(a, b)` — split here into separate light/dark entries so
// the manual theme dropdown can pick a concrete value per side without
// relying on the browser's color-scheme resolution.
var CLAUDE_DESKTOP_SHARED = {
  "--font-sans": "Anthropic Sans, sans-serif",
  "--font-mono": "ui-monospace, monospace",
  "--font-weight-normal": "400",
  "--font-weight-medium": "500",
  "--font-weight-semibold": "600",
  "--font-weight-bold": "700",
  "--font-text-xs-size": "12px",
  "--font-text-sm-size": "14px",
  "--font-text-md-size": "16px",
  "--font-text-lg-size": "20px",
  "--font-heading-xs-size": "12px",
  "--font-heading-sm-size": "14px",
  "--font-heading-md-size": "16px",
  "--font-heading-lg-size": "20px",
  "--font-heading-xl-size": "24px",
  "--font-heading-2xl-size": "28px",
  "--font-heading-3xl-size": "36px",
  "--font-text-xs-line-height": "1.4",
  "--font-text-sm-line-height": "1.4",
  "--font-text-md-line-height": "1.4",
  "--font-text-lg-line-height": "1.25",
  "--font-heading-xs-line-height": "1.4",
  "--font-heading-sm-line-height": "1.4",
  "--font-heading-md-line-height": "1.4",
  "--font-heading-lg-line-height": "1.25",
  "--font-heading-xl-line-height": "1.25",
  "--font-heading-2xl-line-height": "1.1",
  "--font-heading-3xl-line-height": "1",
  "--border-radius-xs": "4px",
  "--border-radius-sm": "6px",
  "--border-radius-md": "8px",
  "--border-radius-lg": "10px",
  "--border-radius-xl": "12px",
  "--border-radius-full": "9999px",
  "--border-width-regular": "0.5px",
  "--shadow-hairline": "0 1px 2px 0 rgba(0, 0, 0, 0.05)",
  "--shadow-sm": "0 1px 3px 0 rgba(0, 0, 0, 0.1), 0 1px 2px -1px rgba(0, 0, 0, 0.1)",
  "--shadow-md": "0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -2px rgba(0, 0, 0, 0.1)",
  "--shadow-lg": "0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -4px rgba(0, 0, 0, 0.1)",
};

var CLIENT_PRESETS = {
  "claude-desktop": {
    light: Object.assign({
      "--color-background-primary": "rgba(255, 255, 255, 1)",
      "--color-background-secondary": "rgba(245, 244, 237, 1)",
      "--color-background-tertiary": "rgba(250, 249, 245, 1)",
      "--color-background-inverse": "rgba(20, 20, 19, 1)",
      "--color-background-ghost": "rgba(255, 255, 255, 0)",
      "--color-background-info": "rgba(214, 228, 246, 1)",
      "--color-background-danger": "rgba(247, 236, 236, 1)",
      "--color-background-success": "rgba(233, 241, 220, 1)",
      "--color-background-warning": "rgba(246, 238, 223, 1)",
      "--color-background-disabled": "rgba(255, 255, 255, 0.5)",
      "--color-text-primary": "rgba(20, 20, 19, 1)",
      "--color-text-secondary": "rgba(61, 61, 58, 1)",
      "--color-text-tertiary": "rgba(115, 114, 108, 1)",
      "--color-text-inverse": "rgba(255, 255, 255, 1)",
      "--color-text-ghost": "rgba(115, 114, 108, 0.5)",
      "--color-text-info": "rgba(50, 102, 173, 1)",
      "--color-text-danger": "rgba(127, 44, 40, 1)",
      "--color-text-success": "rgba(38, 91, 25, 1)",
      "--color-text-warning": "rgba(90, 72, 21, 1)",
      "--color-text-disabled": "rgba(20, 20, 19, 0.5)",
      "--color-border-primary": "rgba(31, 30, 29, 0.4)",
      "--color-border-secondary": "rgba(31, 30, 29, 0.3)",
      "--color-border-tertiary": "rgba(31, 30, 29, 0.15)",
      "--color-border-inverse": "rgba(255, 255, 255, 0.3)",
      "--color-border-ghost": "rgba(31, 30, 29, 0)",
      "--color-border-info": "rgba(70, 130, 213, 1)",
      "--color-border-danger": "rgba(167, 61, 57, 1)",
      "--color-border-success": "rgba(67, 116, 38, 1)",
      "--color-border-warning": "rgba(128, 92, 31, 1)",
      "--color-border-disabled": "rgba(31, 30, 29, 0.1)",
      "--color-ring-primary": "rgba(20, 20, 19, 0.7)",
      "--color-ring-secondary": "rgba(61, 61, 58, 0.7)",
      "--color-ring-inverse": "rgba(255, 255, 255, 0.7)",
      "--color-ring-info": "rgba(50, 102, 173, 0.5)",
      "--color-ring-danger": "rgba(167, 61, 57, 0.5)",
      "--color-ring-success": "rgba(67, 116, 38, 0.5)",
      "--color-ring-warning": "rgba(128, 92, 31, 0.5)",
    }, CLAUDE_DESKTOP_SHARED),
    dark: Object.assign({
      "--color-background-primary": "rgba(48, 48, 46, 1)",
      "--color-background-secondary": "rgba(38, 38, 36, 1)",
      "--color-background-tertiary": "rgba(20, 20, 19, 1)",
      "--color-background-inverse": "rgba(250, 249, 245, 1)",
      "--color-background-ghost": "rgba(48, 48, 46, 0)",
      "--color-background-info": "rgba(37, 62, 95, 1)",
      "--color-background-danger": "rgba(96, 42, 40, 1)",
      "--color-background-success": "rgba(27, 70, 20, 1)",
      "--color-background-warning": "rgba(72, 58, 15, 1)",
      "--color-background-disabled": "rgba(48, 48, 46, 0.5)",
      "--color-text-primary": "rgba(250, 249, 245, 1)",
      "--color-text-secondary": "rgba(194, 192, 182, 1)",
      "--color-text-tertiary": "rgba(156, 154, 146, 1)",
      "--color-text-inverse": "rgba(20, 20, 19, 1)",
      "--color-text-ghost": "rgba(156, 154, 146, 0.5)",
      "--color-text-info": "rgba(128, 170, 221, 1)",
      "--color-text-danger": "rgba(238, 136, 132, 1)",
      "--color-text-success": "rgba(122, 185, 72, 1)",
      "--color-text-warning": "rgba(209, 160, 65, 1)",
      "--color-text-disabled": "rgba(250, 249, 245, 0.5)",
      "--color-border-primary": "rgba(222, 220, 209, 0.4)",
      "--color-border-secondary": "rgba(222, 220, 209, 0.3)",
      "--color-border-tertiary": "rgba(222, 220, 209, 0.15)",
      "--color-border-inverse": "rgba(20, 20, 19, 0.15)",
      "--color-border-ghost": "rgba(222, 220, 209, 0)",
      "--color-border-info": "rgba(70, 130, 213, 1)",
      "--color-border-danger": "rgba(205, 92, 88, 1)",
      "--color-border-success": "rgba(89, 145, 48, 1)",
      "--color-border-warning": "rgba(168, 120, 41, 1)",
      "--color-border-disabled": "rgba(222, 220, 209, 0.1)",
      "--color-ring-primary": "rgba(250, 249, 245, 0.7)",
      "--color-ring-secondary": "rgba(194, 192, 182, 0.7)",
      "--color-ring-inverse": "rgba(20, 20, 19, 0.7)",
      "--color-ring-info": "rgba(128, 170, 221, 0.5)",
      "--color-ring-danger": "rgba(205, 92, 88, 0.5)",
      "--color-ring-success": "rgba(89, 145, 48, 0.5)",
      "--color-ring-warning": "rgba(168, 120, 41, 0.5)",
    }, CLAUDE_DESKTOP_SHARED),
  },
};

// ---------------------------------------------------------------------------
// Host context helpers
// ---------------------------------------------------------------------------

function getControlValue(id) {
  var el = document.getElementById(id);
  return el ? el.value : null;
}

function buildHostContext(frame) {
  var theme = getControlValue("phantom-theme") || "light";
  var platform = getControlValue("phantom-platform") || "web";
  var displayMode = getControlValue("phantom-display-mode") || "inline";
  var clientPreset = getControlValue("phantom-client-preset") || "none";

  var ctx = {
    theme: theme,
    platform: platform,
    displayMode: displayMode,
    availableDisplayModes: ["inline", "fullscreen", "pip"],
    containerDimensions: { maxHeight: 6000 },
  };

  // Apply container width from the frame if available
  if (frame) {
    var w = frame.getBoundingClientRect().width;
    if (w > 0) {
      ctx.containerDimensions.width = Math.round(w);
    }
  }

  // Always include styles in the context — even when empty — so the
  // AppBridge's setHostContext diff detects preset transitions. If
  // we omit the key, the bridge skips comparing it entirely and its
  // internal _hostContext.styles gets stuck on the previous preset
  // (third toggle wouldn't fire a host-context-changed notification).
  var presetVars =
    clientPreset !== "none" && CLIENT_PRESETS[clientPreset]
      ? CLIENT_PRESETS[clientPreset][theme]
      : null;
  ctx.styles = { variables: presetVars || {} };

  return ctx;
}

function applyHostTheme(theme) {
  // The preview shell stays dark; only the simulated artboard reflects
  // the host theme. We surface it as data-host-theme on the body so CSS
  // can style chat bubbles, tool labels, and canvas-bg accordingly.
  document.body.setAttribute("data-host-theme", theme);
}

// Track which CSS variables we've pushed into the app iframe so we can
// strip them when the preset changes. The SDK's applyHostStyleVariables
// only sets values (never removes them), so switching from a preset
// back to "Default" would leave stale vars like --color-background-primary
// hanging around and clobber the layout's own fallbacks.
function clearHostStyleVariables(iframe, varNames) {
  if (!iframe || !iframe.contentDocument || !varNames || !varNames.length) return;
  var docEl = iframe.contentDocument.documentElement;
  if (!docEl) return;
  varNames.forEach(function (name) {
    docEl.style.removeProperty(name);
  });
}

function updateFrameBackground(frame, theme) {
  if (!frame) return;
  if (theme === "dark") {
    frame.style.backgroundColor = "#2b2a27";
  } else {
    frame.style.backgroundColor = "#ffffff";
  }
}

// ---------------------------------------------------------------------------
// Chat simulation
// ---------------------------------------------------------------------------

function buildChatContainer(containerEl, appName) {
  // Chat wrapper — scrollable message list
  var chat = document.createElement("div");
  chat.className = "mcp-chat-container";
  chat.id = "mcp-chat";

  // User message bubble
  var userMsg = document.createElement("div");
  userMsg.className = "mcp-chat-message mcp-chat-user";
  userMsg.innerHTML =
    '<div class="mcp-chat-bubble mcp-chat-bubble-user">' +
    "Show me the " + escapeHtml(appName) + " dashboard" +
    "</div>";
  chat.appendChild(userMsg);

  // Assistant message bubble
  var assistantMsg = document.createElement("div");
  assistantMsg.className = "mcp-chat-message mcp-chat-assistant";
  assistantMsg.innerHTML =
    '<div class="mcp-chat-bubble mcp-chat-bubble-assistant">' +
    "Here's the " + escapeHtml(appName) + " dashboard for you:" +
    "</div>";
  chat.appendChild(assistantMsg);

  // Tool result container (holds the iframe frame + handle)
  var toolResult = document.createElement("div");
  toolResult.className = "mcp-chat-tool-result";
  toolResult.id = "mcp-tool-result";

  var toolLabel = document.createElement("div");
  toolLabel.className = "mcp-chat-tool-label";
  toolLabel.textContent = "Tool Result";
  toolResult.appendChild(toolLabel);

  // Inner wrapper where frame + handle go
  var toolBody = document.createElement("div");
  toolBody.className = "mcp-chat-tool-body";
  toolBody.id = "mcp-tool-body";
  toolResult.appendChild(toolBody);

  chat.appendChild(toolResult);

  containerEl.appendChild(chat);
  return { chat: chat, toolBody: toolBody, toolResult: toolResult };
}

function buildPipWindow(containerEl, appName) {
  var pip = document.createElement("div");
  pip.className = "mcp-pip-window";
  pip.id = "mcp-pip-window";

  var pipHeader = document.createElement("div");
  pipHeader.className = "mcp-pip-header";
  pipHeader.innerHTML =
    '<span class="mcp-pip-title">' + escapeHtml(appName) + "</span>";
  pip.appendChild(pipHeader);

  var pipBody = document.createElement("div");
  pipBody.className = "mcp-pip-body";
  pipBody.id = "mcp-pip-body";
  pip.appendChild(pipBody);

  containerEl.appendChild(pip);

  // External listeners that want to react when the pip moves or resizes.
  // The frame iframe (which is overlaid on top of pip via position:fixed
  // because moving the iframe in the DOM would reload it) hooks into
  // this so it follows the pip.
  var changeListeners = [];
  function notifyChange() {
    for (var i = 0; i < changeListeners.length; i++) changeListeners[i]();
  }
  function onChange(fn) { changeListeners.push(fn); }

  // Make PiP draggable by header
  var dragPip = null;
  pipHeader.addEventListener("pointerdown", function (e) {
    e.preventDefault();
    var rect = pip.getBoundingClientRect();
    var parentRect = containerEl.getBoundingClientRect();
    dragPip = {
      pointerId: e.pointerId,
      startX: e.clientX,
      startY: e.clientY,
      startLeft: rect.left - parentRect.left,
      startTop: rect.top - parentRect.top,
    };
    try { pipHeader.setPointerCapture(e.pointerId); } catch (_) {}
    pipHeader.style.cursor = "grabbing";
  });

  function onPipMove(e) {
    if (!dragPip) return;
    var dx = e.clientX - dragPip.startX;
    var dy = e.clientY - dragPip.startY;
    pip.style.right = "auto";
    pip.style.bottom = "auto";
    pip.style.left = (dragPip.startLeft + dx) + "px";
    pip.style.top = (dragPip.startTop + dy) + "px";
    notifyChange();
  }

  function endPipDrag() {
    if (!dragPip) return;
    try { pipHeader.releasePointerCapture(dragPip.pointerId); } catch (_) {}
    dragPip = null;
    pipHeader.style.cursor = "";
  }

  window.addEventListener("pointermove", onPipMove);
  window.addEventListener("pointerup", endPipDrag);
  window.addEventListener("pointercancel", endPipDrag);

  // The pip uses CSS `resize: both` for the corner resize affordance.
  // ResizeObserver picks that up too, so frame-followers stay in sync.
  if ("ResizeObserver" in window) {
    new ResizeObserver(notifyChange).observe(pip);
  }

  return {
    pip: pip,
    pipBody: pipBody,
    pipHeader: pipHeader,
    onChange: onChange,
  };
}

function escapeHtml(str) {
  var div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

// ---------------------------------------------------------------------------
// Display mode management
// ---------------------------------------------------------------------------

// Leave a vertical gap below the frame so the pip's CSS `resize: both`
// corner affordance is grabbable. Otherwise the fixed-position frame
// iframe captures all clicks over the bottom-right corner.
var PIP_RESIZE_GUTTER = 14;

function syncFrameToPip(frame, pipParts) {
  if (frame.style.position !== "fixed" || frame.style.zIndex !== "21") return;
  var rect = pipParts.pip.getBoundingClientRect();
  var headerH = pipParts.pipHeader ? pipParts.pipHeader.offsetHeight : 32;
  frame.style.top = (rect.top + headerH) + "px";
  frame.style.left = rect.left + "px";
  frame.style.width = rect.width + "px";
  frame.style.height = Math.max(0, rect.height - headerH - PIP_RESIZE_GUTTER) + "px";
}

function applyDisplayMode(mode, els) {
  var containerEl = els.containerEl;
  var frame = els.frame;
  var handle = els.handle;
  var chatParts = els.chatParts;
  var pipParts = els.pipParts;
  var inlineHeight = els.inlineHeight || 0;

  // The iframe NEVER moves in the DOM — browsers reload iframes when
  // they're detached and re-attached, which loses the bridge
  // connection. We use `visibility: hidden` (not `display: none`) on
  // chrome elements when we need to hide them, so the frame's absolute
  // positioning continues to render across modes.
  chatParts.chat.style.visibility = "";
  chatParts.chat.style.display = "";
  chatParts.toolResult.style.display = "";
  chatParts.toolResult.style.visibility = "";
  pipParts.pip.style.display = "none";
  handle.style.display = "";
  frame.style.visibility = "";

  // Reset layout-specific frame styles before applying the new mode
  frame.style.position = "";
  frame.style.top = "";
  frame.style.left = "";
  frame.style.right = "";
  frame.style.bottom = "";
  frame.style.zIndex = "";
  frame.style.minHeight = "";

  // Remove layout classes, re-add base
  containerEl.className = "flex min-h-0 flex-1 overflow-hidden";

  if (mode === "fullscreen") {
    containerEl.classList.add("p-0");
    containerEl.style.flexDirection = "row";
    containerEl.style.position = "relative";
    // Hide chat chrome but keep it in the render tree so the frame
    // (which lives inside chat-tool-body) still renders.
    chatParts.chat.style.visibility = "hidden";
    handle.style.display = "none";
    frame.style.visibility = "visible";
    frame.style.position = "fixed";
    var contRect = containerEl.getBoundingClientRect();
    frame.style.top = contRect.top + "px";
    frame.style.left = contRect.left + "px";
    frame.style.width = contRect.width + "px";
    frame.style.height = contRect.height + "px";
    frame.style.minWidth = "";
    frame.style.minHeight = "0";
    frame.style.borderRadius = "0";
    frame.style.border = "none";
    frame.style.zIndex = "5";
  } else if (mode === "pip") {
    containerEl.classList.add("px-4", "canvas-bg");
    containerEl.style.flexDirection = "column";
    containerEl.style.position = "relative";
    pipParts.pip.style.display = "flex";
    chatParts.toolResult.style.visibility = "hidden";
    handle.style.display = "none";
    // Frame lives inside the chat subtree; we hide the chat's tool
    // result with visibility:hidden which would inherit down. Force
    // the frame visible explicitly so it renders as the pip overlay.
    frame.style.visibility = "visible";
    // Pin the frame fixed under the pip header. The actual coordinates
    // are kept in sync with pip drag/resize via syncFrameToPip().
    frame.style.position = "fixed";
    frame.style.minWidth = "";
    frame.style.minHeight = "0";
    frame.style.borderRadius = "0 0 0.75rem 0.75rem";
    frame.style.border = "none";
    frame.style.zIndex = "21";
    syncFrameToPip(frame, pipParts);
  } else {
    // inline — frame has its natural position inside chat tool body.
    // Height is driven by ui/notifications/size-changed via onsizechange.
    // Re-apply the last reported height so switching back from
    // fullscreen/pip restores the right size without waiting for the
    // app to resize itself.
    containerEl.classList.add("px-4", "canvas-bg");
    containerEl.style.flexDirection = "column";
    frame.style.width = "calc(100% - 14px)";
    frame.style.minWidth = "280px";
    frame.style.minHeight = "";
    frame.style.borderRadius = "";
    frame.style.border = "";
    if (inlineHeight > 0) {
      var clamped = Math.max(200, Math.min(2400, inlineHeight));
      frame.style.height = clamped + "px";
    } else {
      frame.style.height = "";
    }
  }
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

async function renderApp(containerEl, appHtml, appName, mcpEndpoint) {
  // Build chat simulation
  var chatParts = buildChatContainer(containerEl, appName);
  var pipParts = buildPipWindow(containerEl, appName);

  // Wrap the iframe in a resizable frame. Width follows the chat panel
  // (the simulated chat container). Border color is theme-driven via
  // data-host-theme on body so it matches light/dark canvases.
  var frame = document.createElement("div");
  frame.className = "mcp-app-frame shrink-0 rounded-lg shadow-lg relative";
  frame.style.cssText = "width: 100%; min-width: 280px; background-color: #ffffff;";

  // The resize handle lives at the container level — not inside the
  // chat — because it's tied to the iframe's width regardless of
  // display mode. It's positioned (fixed) next to the frame's right
  // edge in inline mode and hidden in fullscreen/pip.
  var handle = document.createElement("div");
  handle.className = "mcp-app-frame-handle cursor-ew-resize rounded-sm touch-none select-none";
  handle.setAttribute("role", "separator");
  handle.setAttribute("aria-orientation", "vertical");
  handle.setAttribute("aria-label", "Resize preview width");
  handle.title = "Drag to resize";

  // Frame goes inside the chat tool body. Handle goes at the container
  // level so it isn't tied to the chat layout.
  chatParts.toolBody.appendChild(frame);
  containerEl.appendChild(handle);

  // The handle floats next to the simulated chat panel (not the
  // iframe) — it resizes the WHOLE chat (bubbles + tool result + frame
  // inside), so the user simulates how the app looks at different chat
  // panel widths. Position the handle just outside the chat's right
  // edge.
  function repositionHandle() {
    if (handle.style.display === "none") return;
    var rect = chatParts.chat.getBoundingClientRect();
    handle.style.position = "fixed";
    handle.style.top = rect.top + "px";
    handle.style.left = (rect.right + 2) + "px";
    handle.style.width = "12px";
    handle.style.height = rect.height + "px";
    handle.style.zIndex = "6";
  }

  // Live width readout in the toolbar + keep the handle aligned with
  // the chat panel as the user resizes it (drag, mode switch, etc.).
  var widthEl = document.getElementById("mcp-frame-width");
  if ("ResizeObserver" in window) {
    var ro = new ResizeObserver(function (entries) {
      var w = Math.round(entries[0].contentRect.width);
      if (widthEl) widthEl.textContent = w + "px";
      repositionHandle();
    });
    ro.observe(chatParts.chat);
  }
  window.addEventListener("scroll", repositionHandle, { passive: true });
  window.addEventListener("resize", repositionHandle);

  // Pointer-capture drag — keeps tracking even when cursor enters the iframe
  var dragState = null;
  var resizeRaf = null;

  function onPointerMove(e) {
    if (!dragState) return;
    var dx = e.clientX - dragState.startX;
    // Resize the simulated chat panel (which contains the bubbles AND
    // the iframe), not the iframe alone. The bound is the visible
    // canvas area minus a small gutter for the handle itself.
    var max = containerEl.clientWidth - 32;
    var next = Math.max(320, Math.min(max, dragState.startWidth + dx));
    chatParts.chat.style.width = next + "px";
    chatParts.chat.style.maxWidth = next + "px";
    repositionHandle();

    // Debounced containerDimensions update via requestAnimationFrame
    if (bridge && !resizeRaf) {
      resizeRaf = requestAnimationFrame(function () {
        resizeRaf = null;
        bridge.setHostContext(buildHostContext(frame));
      });
    }
  }

  function endDrag() {
    if (!dragState) return;
    try { handle.releasePointerCapture(dragState.pointerId); } catch (_) {}
    dragState = null;
    handle.classList.remove("is-dragging");
    document.body.classList.remove("mcp-resizing");
    window.removeEventListener("pointermove", onPointerMove);
    window.removeEventListener("pointerup", endDrag);
    window.removeEventListener("pointercancel", endDrag);

    // Send final dimensions after drag ends
    if (bridge) {
      bridge.setHostContext(buildHostContext(frame));
    }
  }

  handle.addEventListener("pointerdown", function (e) {
    e.preventDefault();
    var rect = chatParts.chat.getBoundingClientRect();
    chatParts.chat.style.width = rect.width + "px";
    chatParts.chat.style.maxWidth = rect.width + "px";
    dragState = {
      pointerId: e.pointerId,
      startX: e.clientX,
      startWidth: rect.width,
    };
    try { handle.setPointerCapture(e.pointerId); } catch (_) {}
    handle.classList.add("is-dragging");
    document.body.classList.add("mcp-resizing");
    window.addEventListener("pointermove", onPointerMove);
    window.addEventListener("pointerup", endDrag);
    window.addEventListener("pointercancel", endDrag);
  });

  handle.addEventListener("dblclick", function () {
    chatParts.chat.style.width = "";
    chatParts.chat.style.maxWidth = "";
    requestAnimationFrame(function () {
      repositionHandle();
      if (bridge) bridge.setHostContext(buildHostContext(frame));
    });
  });

  // Create the app iframe
  var iframe = document.createElement("iframe");
  iframe.className = "block w-full h-full border-0";
  frame.appendChild(iframe);

  // Connect to the MCP server if an endpoint is provided
  var client = null;
  if (mcpEndpoint) {
    try {
      client = new Client(IMPLEMENTATION, {
        capabilities: { extensions: UI_EXTENSION_CAPABILITIES },
      });
      var url = new URL(mcpEndpoint, window.location.origin);
      await client.connect(new StreamableHTTPClientTransport(url));
      console.log("[Preview] MCP client connected:", client.getServerCapabilities());
    } catch (e) {
      console.warn("[Preview] Could not connect to MCP server:", e);
      client = null;
    }
  }

  // Build host capabilities from server capabilities
  var capabilities = { openLinks: {}, logging: {} };
  var serverCaps = client && client.getServerCapabilities && client.getServerCapabilities();
  if (serverCaps && serverCaps.tools) capabilities.serverTools = {};
  if (serverCaps && serverCaps.resources) capabilities.serverResources = {};
  if (serverCaps && serverCaps.prompts) capabilities.serverPrompts = {};

  // Build initial host context from controls
  var initialContext = buildHostContext(frame);

  // Create AppBridge (host side of the ext-apps protocol)
  var bridge = new AppBridge(client, IMPLEMENTATION, capabilities, {
    hostContext: initialContext,
  });

  bridge.onopenlink = async function (params) {
    var u = params.url;
    if (u.startsWith("https://") || u.startsWith("http://")) {
      window.open(u, "_blank");
    }
    return { isError: false };
  };

  bridge.onmessage = async function (params) {
    console.log("[Preview] App message:", params);
    return { isError: false };
  };

  // Last reported content height — replayed when returning to inline
  // (the app only sends size-changed when its own document resizes,
  // so swapping modes won't trigger a fresh notification).
  var lastReportedHeight = 0;

  function applyContentHeight(h) {
    if (typeof h !== "number" || h <= 0) return;
    lastReportedHeight = h;
    var mode = getControlValue("phantom-display-mode") || "inline";
    if (mode !== "inline") return;
    var clamped = Math.max(200, Math.min(2400, h));
    frame.style.height = clamped + "px";
  }

  bridge.onsizechange = function (params) {
    applyContentHeight(params && params.height);
  };

  bridge.onloggingmessage = function (params) {
    console.log("[Preview] [" + params.level + "]:", params.data);
  };

  bridge.oninitialized = function () {
    bridge.sendToolInput({ arguments: {} });
    bridge.sendToolResult({
      content: [{ type: "text", text: "Preview of " + appName }],
    });
    // Same-origin fallback for content-size auto-resize. The SDK's
    // autoResize is supposed to emit ui/notifications/size-changed via
    // setupSizeChangedNotifications, but in this preview's
    // document.write-based architecture the initial firing is racy and
    // the bridge's notification path doesn't reliably surface. Reading
    // doc.body.scrollHeight directly is robust because the inner
    // iframe is same-origin with the host.
    var doc = iframe.contentDocument;
    if (!doc || !doc.body) return;
    var report = function () {
      var h = Math.ceil(doc.body.scrollHeight || doc.body.offsetHeight || 0);
      if (h > 0 && h !== lastReportedHeight) applyContentHeight(h);
    };
    report();
    if ("ResizeObserver" in iframe.contentWindow) {
      try {
        var ro = new iframe.contentWindow.ResizeObserver(report);
        ro.observe(doc.body);
      } catch (_) {}
    }
  };

  // Load the sandbox proxy into the iframe. The proxy is a minimal page
  // that listens for sandbox-resource-ready, then document.write()s the
  // app HTML into its OWN document (same-origin, so scripts work).
  // This is the architecture @mcp-ui/client expects.
  var sandboxUrl = containerEl.dataset.sandboxUrl;
  iframe.src = sandboxUrl;

  // Wait for the proxy to signal ready
  await new Promise(function (resolve, reject) {
    var timeout = setTimeout(function () {
      reject(new Error("Sandbox proxy timed out"));
    }, 10000);

    function onMessage(event) {
      if (event.source === iframe.contentWindow &&
          event.data && event.data.method === "ui/notifications/sandbox-proxy-ready") {
        clearTimeout(timeout);
        window.removeEventListener("message", onMessage);
        resolve();
      }
    }
    window.addEventListener("message", onMessage);
  });

  // Connect bridge to the proxy iframe
  await bridge.connect(
    new PostMessageTransport(iframe.contentWindow)
  );

  // Send the app HTML to the proxy — it will document.write() it
  // into its own document (same-origin, scripts execute properly)
  bridge.sendSandboxResourceReady({ html: appHtml });

  // Display mode elements for layout switching
  var displayEls = {
    containerEl: containerEl,
    frame: frame,
    handle: handle,
    chatParts: chatParts,
    pipParts: pipParts,
    get inlineHeight() { return lastReportedHeight; },
  };

  // Keep the frame visually inside the pip when the pip is dragged or
  // resized. The frame can't be a DOM child of pip — moving the iframe
  // detaches it and triggers a reload — so we sync the fixed-position
  // overlay coordinates instead.
  pipParts.onChange(function () {
    if (getControlValue("phantom-display-mode") === "pip") {
      syncFrameToPip(frame, pipParts);
    }
  });

  // Apply initial display mode and host theme
  var initialMode = getControlValue("phantom-display-mode") || "inline";
  applyDisplayMode(initialMode, displayEls);
  repositionHandle();
  applyHostTheme(initialContext.theme);
  updateFrameBackground(frame, initialContext.theme);

  // Attach change listeners to host context controls
  var controlIds = [
    "phantom-theme",
    "phantom-platform",
    "phantom-display-mode",
    "phantom-client-preset",
  ];

  // Track which CSS variables the current preset pushed in, so we can
  // strip them when the preset changes (the SDK's applyHostStyleVariables
  // only sets values; it never removes them).
  var appliedStyleVars = initialContext.styles && initialContext.styles.variables
    ? Object.keys(initialContext.styles.variables)
    : [];

  controlIds.forEach(function (id) {
    var el = document.getElementById(id);
    if (!el) return;
    el.addEventListener("change", function () {
      // Re-layout if display mode changed
      if (id === "phantom-display-mode") {
        applyDisplayMode(el.value, displayEls);
        repositionHandle();
      }

      var ctx = buildHostContext(frame);

      if (id === "phantom-theme" || id === "phantom-client-preset") {
        // Clear previous preset's vars before applying the new context
        // so swapping presets cleanly resets the cascade.
        clearHostStyleVariables(iframe, appliedStyleVars);
        appliedStyleVars = ctx.styles && ctx.styles.variables
          ? Object.keys(ctx.styles.variables)
          : [];
      }

      bridge.setHostContext(ctx);

      // Update frame background and preview chat theme on theme changes
      if (id === "phantom-theme" || id === "phantom-client-preset") {
        updateFrameBackground(frame, ctx.theme);
        applyHostTheme(ctx.theme);
      }
    });
  });

  return bridge;
}

// ---------------------------------------------------------------------------
// Initialize
// ---------------------------------------------------------------------------

var container = document.getElementById("mcp-app-container");
if (container) {
  var appHtmlB64 = container.dataset.appHtml;
  var appName = container.dataset.appName;
  var mcpEndpoint = container.dataset.mcpEndpoint;
  if (appHtmlB64) {
    // atob() returns Latin-1; decode as UTF-8 to preserve non-ASCII chars
    var appHtml = new TextDecoder().decode(
      Uint8Array.from(atob(appHtmlB64), function (c) { return c.charCodeAt(0); })
    );
    renderApp(container, appHtml, appName, mcpEndpoint).catch(console.error);
  }
}

window.renderMcpApp = renderApp;

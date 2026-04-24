defmodule Test.MCP.Layouts do
  @moduledoc "Layouts for MCP App previews."
  use Phoenix.Component

  @mcp_app_js_path Path.join(__DIR__, "js/mcp_app.js")
  @external_resource @mcp_app_js_path
  @mcp_app_js_b64 @mcp_app_js_path |> File.read!() |> Base.encode64()

  def root(assigns) do
    assigns = assign(assigns, :mcp_app_js_b64, @mcp_app_js_b64)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <title>MCP App</title>
      <style>
        /* Map SDK-supplied vars (background/text/border) to local app
           tokens. SDK has no "action primary" var, so --color-primary is
           an app-level token that simply switches per data-theme. */
        :root, [data-theme="light"] {
          --color-primary: #2563eb;
          --color-bg: var(--color-background-primary, #ffffff);
          --color-surface: var(--color-background-secondary, #f1f5f9);
          --color-text: var(--color-text-primary, #1e293b);
          --color-muted: var(--color-text-secondary, #64748b);
          --radius: var(--border-radius-md, 8px);
        }
        [data-theme="dark"] {
          --color-primary: #60a5fa;
          --color-bg: var(--color-background-primary, #1a1a2e);
          --color-surface: var(--color-background-secondary, #16213e);
          --color-text: var(--color-text-primary, #e2e8f0);
          --color-muted: var(--color-text-secondary, #a0aec0);
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          font-family: var(--font-sans, system-ui, -apple-system, sans-serif);
          color: var(--color-text);
          background: var(--color-bg);
          line-height: 1.5;
        }
      </style>
      <script src={"data:text/javascript;base64,#{@mcp_app_js_b64}"}></script>
    </head>
    <body>
      {@inner_content}
    </body>
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

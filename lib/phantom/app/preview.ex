defmodule Phantom.App.Preview do
  @moduledoc """
  Development preview plug for MCP App resources.

  Lists registered MCP Apps and interact with them in the browser.

  ## Usage

  Mount in your router during development

  <!-- tabs-open -->

  ### Phoenix Router

  ```elixir
  if Mix.env() == :dev do
    forward "/dev/mcp-apps", Phantom.App.Preview,
      router: MyApp.MCPRouter
  end
  ```

  ### Plug Router

  ```elixir
  if Mix.env() == :dev do
    forward "/dev/mcp-apps",
      to: Phantom.App.Preview,
      init_opts: [router: MyApp.MCPRouter]
  end
  ```

  <!-- tabs-close -->

  Then visit `/mcp-apps` to see a list of registered apps, and click
  one to render it in a sandboxed iframe that simulates how MCP hosts
  display apps.

  > #### Development only {: .warning}
  >
  > This plug is intended for development use only. Do not mount it
  > in production as it renders app content without authentication.
  """

  @behaviour Plug
  import Plug.Conn

  @impl Plug
  def init(opts) do
    router = Keyword.fetch!(opts, :router)
    mcp_endpoint = Keyword.get(opts, :mcp_endpoint)
    %{router: router, mcp_endpoint: mcp_endpoint}
  end

  @impl Plug
  def call(conn, %{router: router} = opts) do
    mcp_endpoint = opts[:mcp_endpoint]
    Phantom.Cache.register(router)

    case conn.path_info do
      [] ->
        send_html(conn, render_index(list_app_templates(router), conn))

      ["_sandbox"] ->
        send_sandbox_proxy(conn)

      ["_assets", filename] ->
        serve_static(conn, filename)

      [name, "frame"] ->
        case render_app(router, name, conn) do
          {:ok, html, _csp} ->
            send_html(conn, render_frame(name, html, conn, mcp_endpoint))

          :not_found ->
            conn |> send_resp(404, "App not found: #{name}") |> halt()
        end

      [name] ->
        case render_app(router, name, conn) do
          {:ok, html, csp_header} ->
            conn
            |> maybe_put_csp(csp_header)
            |> send_html(html)

          :not_found ->
            conn |> send_resp(404, "App not found: #{name}") |> halt()
        end

      _ ->
        conn |> send_resp(404, "Not found") |> halt()
    end
  end

  # -- Routing helpers -------------------------------------------------------

  defp list_app_templates(router) do
    nil
    |> Phantom.Cache.list(router, :resource_templates)
    |> Enum.filter(&(&1.scheme == "ui"))
  end

  defp render_app(router, name, conn) do
    case Enum.find(list_app_templates(router), &(&1.name == name)) do
      nil ->
        :not_found

      template ->
        session = Phantom.Session.new("preview-#{name}")

        args =
          if function_exported?(template.handler, template.function, 3) do
            [%{}, session, conn]
          else
            [%{}, session]
          end

        case apply(template.handler, template.function, args) do
          {:reply, %{contents: [%{text: html} | _]} = result, _session} ->
            csp = extract_csp_from_meta(result[:_meta])
            {:ok, html, csp}

          {:reply, %{text: html}, _session} ->
            {:ok, html, nil}

          _ ->
            {:ok, "<p>Error rendering app: #{name}</p>", nil}
        end
    end
  end

  defp extract_csp_from_meta(%{ui: %{csp: csp}}) when map_size(csp) > 0 do
    Phantom.App.CSP.build(
      connect_domains: Map.get(csp, :connectDomains, []),
      resource_domains: Map.get(csp, :resourceDomains, []),
      frame_domains: Map.get(csp, :frameDomains, []),
      base_uri_domains: Map.get(csp, :baseUriDomains, [])
    )
  end

  defp extract_csp_from_meta(_), do: nil

  defp maybe_put_csp(conn, nil), do: conn
  defp maybe_put_csp(conn, csp), do: put_resp_header(conn, "content-security-policy", csp)

  # -- Static assets ---------------------------------------------------------

  @allowed_assets ~w[preview.js preview.css]
  defp serve_static(conn, filename) when filename in @allowed_assets do
    path = Path.join(Application.app_dir(:phantom_mcp, "priv/static"), filename)

    case File.read(path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type(mime_for(filename))
        |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
        |> send_resp(200, content)
        |> halt()

      {:error, _} ->
        conn |> send_resp(404, "Not found") |> halt()
    end
  end

  defp serve_static(conn, _filename) do
    conn |> send_resp(404, "Not found") |> halt()
  end

  defp mime_for(filename) do
    case Path.extname(filename) do
      ".js" -> "application/javascript"
      ".css" -> "text/css"
      _ -> "application/octet-stream"
    end
  end

  # -- Sandbox proxy ---------------------------------------------------------

  defp send_sandbox_proxy(conn) do
    # Sandbox proxy per the @mcp-ui/client walkthrough.
    # The proxy receives app HTML from the host via postMessage, then
    # document.write()s it into its OWN document (same-origin).
    # This is the expected architecture for AppBridge/AppRenderer.
    html = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <style>html, body { margin: 0; padding: 0; width: 100%; height: 100%; }</style>
    </head>
    <body>
    <script>
    window.addEventListener("message", function(event) {
      var data = event.data;
      if (!data || typeof data !== "object") return;
      if (data.method === "ui/notifications/sandbox-resource-ready") {
        var html = (data.params || {}).html;
        if (html) {
          document.open();
          document.write(html);
          document.close();
        }
      }
    });
    window.parent.postMessage({
      method: "ui/notifications/sandbox-proxy-ready",
      params: {}
    }, "*");
    </script>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
    |> halt()
  end

  defp send_html(conn, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
    |> halt()
  end

  defp base_path(conn) do
    "/" <> Enum.join(conn.script_name, "/")
  end

  defp assets_path(conn), do: base_path(conn) <> "/_assets"

  # Bust per-request in dev so iterating on preview.css/js doesn't require
  # clearing the browser cache. The Preview plug is dev-only anyway.
  defp asset_version, do: System.system_time(:millisecond) |> Integer.to_string()

  # -- Templates -------------------------------------------------------------

  defp render_index(templates, conn) do
    base = base_path(conn)
    assets = assets_path(conn)

    items =
      Enum.map_join(templates, "\n", fn t ->
        desc = t.description || "No description provided."
        uri = t.uri_template || ""

        """
        <li>
          <a href="#{base}/#{t.name}/frame"
             class="group block rounded-xl border border-zinc-800/60 bg-phantom-surface p-5 transition-all duration-200 hover:border-phantom/40 hover:bg-phantom-surface-hover hover:shadow-[0_0_20px_-4px] hover:shadow-phantom/15">
            <div class="flex items-center justify-between gap-3">
              <span class="font-mono text-sm font-semibold text-phantom group-hover:text-phantom-glow">#{t.name}</span>
              <span class="text-zinc-600 transition-all duration-200 group-hover:translate-x-0.5 group-hover:text-phantom" aria-hidden="true">&rarr;</span>
            </div>
            <p class="mt-2 text-sm leading-relaxed text-zinc-400">#{desc}</p>
            #{if uri != "", do: ~s(<code class="mt-3 inline-block rounded-md border border-zinc-700/50 bg-zinc-800/50 px-2.5 py-1 text-xs text-zinc-500 font-mono">#{uri}</code>), else: ""}
          </a>
        </li>
        """
      end)

    body =
      if templates == [] do
        """
        <div class="rounded-xl border border-dashed border-zinc-700 bg-phantom-surface p-12 text-center">
          <div class="text-3xl mb-3 opacity-30">&#x1F47B;</div>
          <p class="font-semibold text-zinc-200">No app resources registered</p>
          <p class="mt-2 text-sm text-zinc-500">Define a resource with <code class="rounded-md border border-zinc-700/50 bg-zinc-800/50 px-1.5 py-0.5 text-xs font-mono">scheme: "ui"</code> in your MCP router.</p>
        </div>
        """
      else
        count = length(templates)
        label = if count == 1, do: "app", else: "apps"

        """
        <p class="mb-5 text-sm text-zinc-500">#{count} #{label} registered</p>
        <ul class="grid gap-3">#{items}</ul>
        """
      end

    """
    <!DOCTYPE html>
    <html lang="en" class="dark antialiased">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Phantom &middot; App Preview</title>
      <link rel="stylesheet" href="#{assets}/preview.css?v=#{asset_version()}">
    </head>
    <body class="bg-zinc-950 text-zinc-100 min-h-screen">
      <main class="mx-auto max-w-2xl px-6 pt-16 pb-12">
        <header class="mb-10">
          <div class="flex items-center gap-2.5 mb-3">
            <div class="size-7 rounded-lg bg-phantom/15 border border-phantom/25 flex items-center justify-center text-phantom text-sm">&#x1F47B;</div>
            <span class="text-[11px] font-bold uppercase tracking-[0.15em] text-phantom/70">Phantom MCP</span>
          </div>
          <h1 class="text-3xl font-bold tracking-tight text-white">App Preview</h1>
        </header>
        #{body}
        <footer class="mt-14 border-t border-zinc-800/60 pt-5 text-xs text-zinc-600">
          Development preview &mdash; do not expose in production
        </footer>
      </main>
    </body>
    </html>
    """
  end

  defp render_frame(name, app_html, conn, mcp_endpoint) do
    assets = assets_path(conn)
    back_url = base_path(conn)
    app_html_b64 = Base.encode64(app_html)

    endpoint_attr =
      if mcp_endpoint, do: ~s( data-mcp-endpoint="#{mcp_endpoint}"), else: ""

    """
    <!DOCTYPE html>
    <html lang="en" class="h-full dark antialiased">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Phantom &middot; #{name}</title>
      <link rel="stylesheet" href="#{assets}/preview.css?v=#{asset_version()}">
    </head>
    <body class="flex h-full flex-col bg-zinc-950 text-zinc-100 m-0 p-0">
      <nav class="flex shrink-0 items-center gap-3 border-b border-zinc-800/60 bg-phantom-surface px-5 py-2.5 sticky top-0 z-10">
        <a href="#{back_url}" class="inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium text-zinc-400 transition-all duration-150 hover:bg-zinc-800 hover:text-zinc-100">
          <span aria-hidden="true">&larr;</span> Back
        </a>
        <span class="h-4 w-px bg-zinc-800" aria-hidden="true"></span>
        <span class="text-[11px] font-bold uppercase tracking-[0.12em] text-zinc-600">Preview</span>
        <code class="rounded-md border border-phantom/25 bg-phantom/10 px-2.5 py-0.5 text-xs font-mono text-phantom">#{name}</code>
        <span class="ml-auto"></span>
        <span class="flex items-center gap-2.5" title="Drag handle to resize">
          <span class="text-[11px] font-bold uppercase tracking-[0.12em] text-zinc-600">Width</span>
          <code class="rounded-md border border-zinc-800 bg-zinc-900 px-2.5 py-0.5 text-xs font-mono text-zinc-400 tabular-nums" id="mcp-frame-width">&mdash;</code>
        </span>
      </nav>
      <div class="flex shrink-0 items-center gap-4 border-b border-zinc-800/60 bg-phantom-surface px-5 py-1.5 sticky top-[41px] z-10" id="phantom-controls">
        <label class="phantom-control-group">
          <span class="phantom-control-label">Theme</span>
          <select id="phantom-theme" class="phantom-control-select">
            <option value="light" selected>light</option>
            <option value="dark">dark</option>
          </select>
        </label>
        <label class="phantom-control-group">
          <span class="phantom-control-label">Platform</span>
          <select id="phantom-platform" class="phantom-control-select">
            <option value="web" selected>web</option>
            <option value="desktop">desktop</option>
            <option value="mobile">mobile</option>
          </select>
        </label>
        <label class="phantom-control-group">
          <span class="phantom-control-label">Display</span>
          <select id="phantom-display-mode" class="phantom-control-select">
            <option value="inline" selected>inline</option>
            <option value="fullscreen">fullscreen</option>
            <option value="pip">pip</option>
          </select>
        </label>
        <label class="phantom-control-group">
          <span class="phantom-control-label">Client</span>
          <select id="phantom-client-preset" class="phantom-control-select">
            <option value="none" selected>Default</option>
            <option value="claude-desktop">Claude Desktop</option>
          </select>
        </label>
      </div>
      <div id="mcp-app-container"
           class="flex min-h-0 flex-1 flex-row items-stretch overflow-hidden p-4 canvas-bg"
           data-app-name="#{name}"
           data-app-html="#{app_html_b64}"
           data-sandbox-url="#{base_path(conn)}/_sandbox"#{endpoint_attr}></div>
      <script src="#{assets}/preview.js?v=#{asset_version()}"></script>
    </body>
    </html>
    """
  end
end

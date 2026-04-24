defmodule Phantom.App do
  @moduledoc """
  Behaviour for MCP App UI resources.

  [MCP Apps](https://apps.extensions.modelcontextprotocol.io/) are interactive
  HTML interfaces that render inside MCP hosts (like Claude Desktop) as
  sandboxed iframes. `Phantom.App` works like a Phoenix Controller — it's
  a Plug pipeline that renders HTML and provides metadata to the host.

  > #### Client-side JavaScript is required {: .warning}
  >
  > The rendered HTML **must** include JavaScript from the
  > [`@modelcontextprotocol/ext-apps`](https://www.npmjs.com/package/@modelcontextprotocol/ext-apps)
  > npm package. This JS handles the `postMessage` handshake with the host.
  > Without it, the host renders a blank iframe.
  >
  > See the [MCP Apps JS SDK](https://apps.extensions.modelcontextprotocol.io/specification/architecture)
  > for the full client-side API, including theming, tool input/result
  > handling, and host communication.

  ## Quick Start

  1. Define your app module
  2. Register it on a tool in your MCP router
  3. Bundle the ext-apps JavaScript client
  4. Include the bundle in your root layout via a base64 data URI

  <!-- tabs-open -->

  ### App module

      defmodule MyApp.MCP.DashboardApp do
        use Phantom.App,
          permissions: [:clipboard_write],
          prefers_border: true

        use Phoenix.Component
        import Phoenix.Controller, only: [put_root_layout: 2, put_layout: 2]

        plug :put_root_layout, html: {MyAppWeb.MCP.Layouts, :root}
        plug :put_layout, html: {MyAppWeb.MCP.Layouts, :app}

        plug Phantom.App.CSP,
          connect_domains: ["https://api.example.com"]

        @impl Phantom.App
        def mount(_params, session) do
          {:ok, %{user: session.assigns.user}}
        end

        @impl Phantom.App
        def render(assigns) do
          ~H\"\"\"
          <h1>Hello {@user.name}</h1>
          \"\"\"
        end
      end

  ### Router registration

      defmodule MyApp.MCP.Router do
        use Phantom.Router, name: "MyApp", vsn: "1.0"

        @description "Open the dashboard"
        tool :dashboard, app: MyApp.MCP.DashboardApp
        def dashboard(_params, session), do: {:reply, Phantom.Tool.text("ok"), session}
      end

  ### Layout with JavaScript bundle

  The ext-apps JS bundle **must** be base64-encoded and loaded via a
  `data:` URI. Inline `<script>` tags break because the host injects
  the HTML via `document.write()` and minified JS contains backticks
  that conflict with the host's parser.

      defmodule MyAppWeb.MCP.Layouts do
        use Phoenix.Component

        @mcp_app_js_path Path.join(:code.priv_dir(:my_app), "static/mcp_app.js")
        @external_resource @mcp_app_js_path
        @mcp_app_js_b64 @mcp_app_js_path |> File.read!() |> Base.encode64()

        def root(assigns) do
          assigns = assign(assigns, :mcp_app_js_b64, @mcp_app_js_b64)

          ~H\"\"\"
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="UTF-8" />
            <script src={"data:text/javascript;base64,\#{@mcp_app_js_b64}"}></script>
          </head>
          <body>{@inner_content}</body>
          </html>
          \"\"\"
        end
      end

  <!-- tabs-close -->

  For a complete walkthrough including the JavaScript entry point, event
  handling, esbuild configuration, and framework-specific examples (React,
  Vue, Svelte), see the [Building MCP Apps](`e:phantom_mcp:mcp_apps.md`)
  guide.

  ## Options

    * `:permissions` - Sandbox permissions: `:camera`, `:microphone`,
      `:geolocation`, `:clipboard_write`
    * `:domain` - Dedicated sandbox origin hint
    * `:prefers_border` - Whether the app prefers a visible border

  These can also be set dynamically via `put_permissions/2`,
  `put_domain/2`, and `put_prefers_border/2`.

  ## Visibility

  Tools with an `app:` control who can see and invoke them via the
  `visibility` option on the tool's `:ui` metadata. Visibility is a
  list of audience strings:

    * `"model"` — the tool appears in `tools/list` and the LLM can
      call it. This is the normal path: the model decides when to
      invoke the tool, and the host renders the app UI alongside the
      result.

    * `"app"` — the tool can be called by other MCP App UIs running
      in the same session (via `app.callServerTool()`). This allows
      one app to compose with another's tools.

  The default visibility is `[:model, :app]` — both the model and
  other apps can see and call the tool.

  Common patterns:

      # Default: model and apps can both call it
      tool :dashboard, app: MyApp.DashboardApp

      # App-only: hidden from the model, only callable from other apps.
      # Useful for helper tools that power an app's UI but shouldn't
      # clutter the model's tool list.
      tool :fetch_chart_data, app: MyApp.ChartDataApp,
        ui: [visibility: [:app]]

      # Model-only: the model can call it but other apps cannot.
      tool :admin_panel, app: MyApp.AdminApp,
        ui: [visibility: [:model]]

  ## Dev Preview

  Mount `Phantom.App.Preview` in your router during development to
  browse and test your MCP Apps in the browser:

      # Phoenix Router
      if Mix.env() == :dev do
        forward "/mcp-apps", Phantom.App.Preview,
          router: MyApp.MCP.Router,
          mcp_endpoint: "/mcp"
      end

  Visit `/mcp-apps` to see a list of registered apps with iframe
  previews. The preview connects to your MCP server so interactive
  features (tool calls, resource listing) work end-to-end. See
  `Phantom.App.Preview` for details.
  """

  import Plug.Conn

  @typedoc """
  Output accepted from `c:render/1`.

  Plain strings, iodata, and any struct that implements `Phoenix.HTML.Safe`
  (e.g. `Phoenix.LiveView.Rendered` from `~H`) are all valid.
  """
  @type rendered :: binary() | iodata() | struct()

  @callback mount(params :: map(), session :: Phantom.Session.t()) :: {:ok, map()}
  @callback render(assigns :: map()) :: rendered()

  defmacro __using__(opts) do
    permissions = Keyword.get(opts, :permissions)
    domain = Keyword.get(opts, :domain)
    prefers_border = Keyword.get(opts, :prefers_border)

    quote do
      use Plug.Builder
      @behaviour Phantom.App

      if unquote(permissions) do
        plug :__phantom_put_permissions, unquote(permissions)
      end

      if unquote(domain) do
        plug :__phantom_put_domain, unquote(domain)
      end

      if unquote(prefers_border) do
        plug :__phantom_put_prefers_border, unquote(prefers_border)
      end

      defp __phantom_put_permissions(conn, perms),
        do: Phantom.App.put_permissions(conn, perms)

      defp __phantom_put_domain(conn, domain),
        do: Phantom.App.put_domain(conn, domain)

      defp __phantom_put_prefers_border(conn, val),
        do: Phantom.App.put_prefers_border(conn, val)

      @impl Phantom.App
      def mount(_params, _session), do: {:ok, %{}}
      defoverridable mount: 2

      @doc false
      def __phantom_app__(params, session) do
        __phantom_app__(params, session, Plug.Test.conn(:get, "/"))
      end

      @doc false
      def __phantom_app__(params, session, conn) do
        conn =
          conn
          |> Plug.Conn.put_private(:phantom_app, %{params: params, session: session})
          |> Plug.Conn.put_private(:phantom_ui_csp, Phantom.App.default_csp())
          |> __MODULE__.call(__MODULE__.init([]))

        ui_meta = Phantom.App.collect_ui_meta(conn)

        {:ok, extra_assigns} = mount(params, session)

        assigns =
          extra_assigns
          |> Map.put(:__changed__, nil)
          |> Map.put(:session, session)
          |> Map.put(:params, params)
          |> Map.put(:conn, conn)

        html =
          assigns
          |> render()
          |> Phantom.App.to_html()
          |> Phantom.App.apply_layouts(conn)

        uri = if session.request, do: session.request.spec.uri_template

        content =
          Phantom.Utils.remove_nils(%{
            text: html,
            uri: uri,
            mimeType: "text/html;profile=mcp-app"
          })

        {:reply, %{contents: [content], _meta: ui_meta}, session}
      end
    end
  end

  @doc "Set sandbox permissions on the conn for `_meta.ui.permissions`."
  @spec put_permissions(Plug.Conn.t(), [atom()]) :: Plug.Conn.t()
  def put_permissions(conn, permissions) when is_list(permissions) do
    put_private(conn, :phantom_ui_permissions, permissions)
  end

  @doc "Set the sandbox domain on the conn for `_meta.ui.domain`."
  @spec put_domain(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_domain(conn, domain) when is_binary(domain) do
    put_private(conn, :phantom_ui_domain, domain)
  end

  @doc "Set the border preference on the conn for `_meta.ui.prefersBorder`."
  @spec put_prefers_border(Plug.Conn.t(), boolean()) :: Plug.Conn.t()
  def put_prefers_border(conn, prefers_border) when is_boolean(prefers_border) do
    put_private(conn, :phantom_ui_prefers_border, prefers_border)
  end

  @doc """
  The restrictive default CSP per the MCP Apps spec.

  Applied automatically when no `Phantom.App.CSP` plug overrides it.
  """
  def default_csp do
    %{
      "default-src": "'none'",
      "script-src": "'self' 'unsafe-inline'",
      "style-src": "'self' 'unsafe-inline'",
      "img-src": "'self' data:",
      "media-src": "'self' data:",
      "connect-src": "'none'"
    }
  end

  @doc false
  def collect_ui_meta(conn) do
    csp = conn.private[:phantom_ui_csp]
    permissions = conn.private[:phantom_ui_permissions]
    domain = conn.private[:phantom_ui_domain]
    prefers_border = conn.private[:phantom_ui_prefers_border]

    ui =
      Phantom.Utils.remove_nils(%{
        csp: csp,
        permissions: build_permissions(permissions),
        domain: domain,
        prefersBorder: prefers_border
      })

    %{ui: ui}
  end

  defp build_permissions(nil), do: nil
  defp build_permissions([]), do: nil

  defp build_permissions(perms) do
    Map.new(perms, fn
      :clipboard_write -> {:clipboardWrite, %{}}
      perm -> {perm, %{}}
    end)
  end

  @phoenix_html_safe Code.ensure_loaded?(Phoenix.HTML.Safe)

  @doc """
  Convert render output to an HTML binary string.
  """
  @spec to_html(binary() | iodata() | struct()) :: binary()
  def to_html(content) when is_binary(content), do: content

  if @phoenix_html_safe do
    def to_html(%_{} = struct) do
      struct |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    end
  else
    def to_html(content), do: content
  end

  def to_html(content), do: IO.iodata_to_binary(content)

  @doc false
  @spec apply_layouts(binary(), Plug.Conn.t()) :: binary()
  def apply_layouts(html, conn) do
    if Code.ensure_loaded?(Phoenix.Controller) do
      html
      |> apply_layout(Phoenix.Controller.layout(conn, "html"))
      |> apply_layout(Phoenix.Controller.root_layout(conn, "html"))
    else
      html
    end
  end

  defp apply_layout(html, false), do: html

  defp apply_layout(html, {module, template}) when is_atom(module) and is_atom(template) do
    assigns = %{inner_content: {:safe, html}, __changed__: nil}
    apply(module, template, [assigns]) |> to_html()
  end
end

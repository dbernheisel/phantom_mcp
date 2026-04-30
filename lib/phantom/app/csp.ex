defmodule Phantom.App.CSP do
  @moduledoc """
  Content Security Policy plug for MCP App resources.

  When used inside a `Phantom.App` module, this plug:
  1. Sets the `Content-Security-Policy` response header
  2. Stores UI metadata in `conn.private[:phantom_ui]` for the MCP `_meta.ui` response

  ## Usage in a Phantom.App module

      defmodule MyApp.DashboardApp do
        use Phantom.App,
          permissions: [:clipboard_write],
          prefers_border: true

        plug Phantom.App.CSP,
          connect_domains: ["https://api.example.com"],
          resource_domains: ["https://cdn.example.com"],

        def mount(assigns), do: ...
        def render(assigns), do: ...
      end

  ## Usage in a Phoenix pipeline

      import Phantom.App.CSP

      pipeline :mcp_apps do
        plug :put_content_security_policy,
          connect_domains: ["https://api.example.com"]
      end

  ## Options

    * `:connect_domains` - Origins allowed for fetch/XHR/WebSocket
    * `:resource_domains` - Origins for scripts, images, styles, fonts, media
    * `:frame_domains` - Origins for nested iframes
    * `:base_uri_domains` - Origins for document base-uri
    * `:permissions` - Sandbox permissions (`:camera`, `:microphone`, `:geolocation`, `:clipboard_write`)
    * `:domain` - Dedicated sandbox origin hint
    * `:prefers_border` - Whether the app prefers a visible border
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn
    |> put_content_security_policy(opts)
    |> put_private(:phantom_ui_csp, csp_meta(opts))
  end

  @doc """
  Set the `Content-Security-Policy` response header.

      conn
      |> put_content_security_policy(
        connect_domains: ["https://api.example.com"],
        resource_domains: ["https://cdn.example.com"]
      )
  """
  @spec put_content_security_policy(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def put_content_security_policy(conn, opts) do
    put_resp_header(conn, "content-security-policy", build(opts))
  end

  @doc """
  Build a CSP header string from domain options.

  Returns a policy string following the MCP Apps spec defaults.
  """
  @spec build(Keyword.t()) :: String.t()
  def build(opts) when is_list(opts) do
    connect = Keyword.get(opts, :connect_domains, [])
    resource = Keyword.get(opts, :resource_domains, [])
    frame = Keyword.get(opts, :frame_domains, [])
    base_uri = Keyword.get(opts, :base_uri_domains, [])

    directives = [
      {"default-src", ["'none'"]},
      {"script-src", ["'self'", "'unsafe-inline'"] ++ resource},
      {"style-src", ["'self'", "'unsafe-inline'"] ++ resource},
      {"img-src", ["'self'", "data:"] ++ resource},
      {"font-src", if(resource != [], do: ["'self'"] ++ resource, else: nil)},
      {"media-src", ["'self'", "data:"] ++ resource},
      {"connect-src", if(connect != [], do: ["'self'"] ++ connect, else: ["'none'"])},
      {"frame-src", if(frame != [], do: frame, else: nil)},
      {"base-uri", if(base_uri != [], do: base_uri, else: nil)}
    ]

    directives
    |> Enum.reject(fn {_name, sources} -> is_nil(sources) end)
    |> Enum.map_join("; ", fn {name, sources} ->
      "#{name} #{Enum.join(sources, " ")}"
    end)
  end

  @doc """
  Build a CSP header string from a `Phantom.UI` struct.
  """
  @spec build_from_ui(Phantom.UI.t() | nil) :: String.t()
  def build_from_ui(nil), do: build([])

  def build_from_ui(%Phantom.UI{} = ui) do
    build(
      connect_domains: ui.connect_domains || [],
      resource_domains: ui.resource_domains || [],
      frame_domains: ui.frame_domains || [],
      base_uri_domains: ui.base_uri_domains || []
    )
  end

  @csp_keys ~w[connect_domains resource_domains frame_domains base_uri_domains]a

  defp csp_meta(opts) do
    csp_opts = Keyword.take(opts, @csp_keys)

    if csp_opts == [] do
      nil
    else
      Phantom.Utils.remove_nils(%{
        connectDomains: csp_opts[:connect_domains],
        resourceDomains: csp_opts[:resource_domains],
        frameDomains: csp_opts[:frame_domains],
        baseUriDomains: csp_opts[:base_uri_domains]
      })
    end
  end
end

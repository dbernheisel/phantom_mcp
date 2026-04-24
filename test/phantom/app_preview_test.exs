defmodule Phantom.App.PreviewTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Phantom.App.Preview

  defmodule PreviewApp do
    use Phantom.App

    plug Phantom.App.CSP,
      connect_domains: ["https://api.example.com"]

    @impl true
    def render(_assigns), do: "<h1>Preview App</h1>"
  end

  defmodule PreviewRouter do
    use Phantom.Router, name: "PreviewTest", vsn: "1.0"

    @description "An app for preview testing"
    tool :preview_app, app: PreviewApp

    def preview_app(_params, session),
      do: {:reply, Phantom.Tool.text("ok"), session}
  end

  setup do
    Phantom.Cache.register(PreviewRouter)
    opts = Preview.init(router: PreviewRouter)
    %{opts: opts}
  end

  describe "GET /" do
    test "lists only ui:// resource templates", %{opts: opts} do
      conn =
        conn(:get, "/")
        |> Preview.call(opts)

      assert conn.status == 200
      body = conn.resp_body
      assert body =~ "preview_app"
    end

    test "returns HTML content type", %{opts: opts} do
      conn =
        conn(:get, "/")
        |> Preview.call(opts)

      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/html"
    end
  end

  describe "GET /:name" do
    test "renders the app HTML", %{opts: opts} do
      conn =
        conn(:get, "/preview_app")
        |> Preview.call(opts)

      assert conn.status == 200
      assert conn.resp_body =~ "<h1>Preview App</h1>"
    end

    test "sets CSP header from app's plug pipeline", %{opts: opts} do
      conn =
        conn(:get, "/preview_app")
        |> Preview.call(opts)

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src"
      assert csp =~ "https://api.example.com"
    end

    test "returns 404 for unknown app", %{opts: opts} do
      conn =
        conn(:get, "/nonexistent")
        |> Preview.call(opts)

      assert conn.status == 404
    end
  end

  describe "GET /:name/frame" do
    test "renders AppBridge host page", %{opts: opts} do
      conn =
        conn(:get, "/preview_app/frame")
        |> Preview.call(opts)

      assert conn.status == 200
      body = conn.resp_body
      assert body =~ "mcp-app-container"
      assert body =~ "data-app-name=\"preview_app\""
      assert body =~ "data-app-html="
      assert body =~ "_assets/preview.js"
    end

    test "renders host context controls bar", %{opts: opts} do
      conn =
        conn(:get, "/preview_app/frame")
        |> Preview.call(opts)

      body = conn.resp_body
      assert body =~ "phantom-controls"
      assert body =~ "phantom-theme"
      assert body =~ "phantom-platform"
      assert body =~ "phantom-display-mode"
      assert body =~ "phantom-client-preset"
    end

    test "controls bar includes expected options", %{opts: opts} do
      conn =
        conn(:get, "/preview_app/frame")
        |> Preview.call(opts)

      body = conn.resp_body

      # Theme options
      assert body =~ ~s(value="light")
      assert body =~ ~s(value="dark")

      # Platform options
      assert body =~ ~s(value="web")
      assert body =~ ~s(value="desktop")
      assert body =~ ~s(value="mobile")

      # Display mode options
      assert body =~ ~s(value="inline")
      assert body =~ ~s(value="fullscreen")
      assert body =~ ~s(value="pip")

      # Client preset options
      assert body =~ ~s(value="none")
      assert body =~ "Default"
      assert body =~ "Claude Desktop"
    end
  end

  describe "GET /_assets" do
    test "serves preview.js", %{opts: opts} do
      conn =
        :get
        |> conn("/_assets/preview.js")
        |> Preview.call(opts)

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "javascript"
    end

    test "serves preview.css", %{opts: opts} do
      conn =
        :get
        |> conn("/_assets/preview.css")
        |> Preview.call(opts)

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "css"
    end

    test "returns 404 for unknown assets", %{opts: opts} do
      conn =
        :get
        |> conn("/_assets/evil.js")
        |> Preview.call(opts)

      assert conn.status == 404
    end
  end
end

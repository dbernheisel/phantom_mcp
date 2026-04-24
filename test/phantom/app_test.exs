defmodule Phantom.AppTest do
  use ExUnit.Case, async: true

  defp app_html({:reply, %{contents: [%{text: html} | _]}, _session}), do: html
  defp app_meta({:reply, %{_meta: meta}, _session}), do: meta

  defmodule SimpleApp do
    use Phantom.App

    @impl true
    def render(_assigns) do
      "<h1>Plain HTML</h1>"
    end
  end

  defmodule MountApp do
    use Phantom.App

    @impl true
    def mount(_params, session) do
      {:ok, %{greeting: "Hello from #{session.assigns[:user_name] || "World"}"}}
    end

    @impl true
    def render(assigns) do
      "<h1>#{assigns.greeting}</h1>"
    end
  end

  defmodule AppWithCSP do
    use Phantom.App,
      permissions: [:clipboard_write],
      prefers_border: true

    plug Phantom.App.CSP,
      connect_domains: ["https://api.example.com"]

    @impl true
    def render(_assigns) do
      "<h1>Dashboard</h1>"
    end
  end

  describe "basic behaviour" do
    test "generates __phantom_app__/2 handler" do
      assert function_exported?(SimpleApp, :__phantom_app__, 2)
    end

    test "renders plain HTML" do
      session = Phantom.Session.new("test")
      result = SimpleApp.__phantom_app__(%{}, session)

      assert app_html(result) == "<h1>Plain HTML</h1>"
    end

    test "mount receives params and session" do
      session = Phantom.Session.new("test", assigns: %{user_name: "Alice"})
      result = MountApp.__phantom_app__(%{}, session)

      assert app_html(result) == "<h1>Hello from Alice</h1>"
    end

    test "default mount returns empty assigns" do
      session = Phantom.Session.new("test")
      result = SimpleApp.__phantom_app__(%{}, session)

      assert app_html(result) == "<h1>Plain HTML</h1>"
    end

    test "assigns include session and params" do
      defmodule AssignsApp do
        use Phantom.App

        @impl true
        def render(assigns) do
          "session:#{assigns.session.id},params:#{inspect(assigns.params)}"
        end
      end

      session = Phantom.Session.new("test-id")
      result = AssignsApp.__phantom_app__(%{"key" => "val"}, session)

      assert app_html(result) =~ "session:test-id"
      assert app_html(result) =~ ~s(params:%{"key" => "val"})
    end
  end

  describe "plug pipeline" do
    test "CSP plug runs and sets _meta.ui.csp in response" do
      session = Phantom.Session.new("test")
      result = AppWithCSP.__phantom_app__(%{}, session)

      assert app_html(result) == "<h1>Dashboard</h1>"
      ui_meta = app_meta(result).ui
      assert %{csp: %{connectDomains: ["https://api.example.com"]}} = ui_meta
      assert %{permissions: %{clipboardWrite: %{}}} = ui_meta
      assert ui_meta.prefersBorder == true
    end

    test "app without plugs always includes _meta.ui" do
      session = Phantom.Session.new("test")
      result = SimpleApp.__phantom_app__(%{}, session)

      assert app_html(result) == "<h1>Plain HTML</h1>"
      # _meta.ui is always present (host needs it for CSP defaults)
      assert %{ui: _} = app_meta(result)
    end

    test "CSP plug also sets Content-Security-Policy header on conn" do
      conn = Plug.Test.conn(:get, "/")
      conn = AppWithCSP.call(conn, AppWithCSP.init([]))

      [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src"
      assert csp =~ "https://api.example.com"
    end
  end

  describe "layout support" do
    defmodule TestLayouts do
      use Phoenix.Component

      def root(assigns) do
        ~H"""
        <!DOCTYPE html>
        <html>
        <head><title>Layout Test</title></head>
        <body>{@inner_content}</body>
        </html>
        """
      end

      def app(assigns) do
        ~H"""
        <main class="app">{@inner_content}</main>
        """
      end
    end

    defmodule LayoutApp do
      use Phantom.App
      use Phoenix.Component
      import Phoenix.Controller, only: [put_root_layout: 2]

      plug :put_root_layout, html: {TestLayouts, :root}

      @impl Phantom.App
      def render(assigns) do
        ~H"<h1>Content inside layout</h1>"
      end
    end

    defmodule BothLayoutsApp do
      use Phantom.App
      use Phoenix.Component
      import Phoenix.Controller, only: [put_root_layout: 2, put_layout: 2]

      plug :put_root_layout, html: {TestLayouts, :root}
      plug :put_layout, html: {TestLayouts, :app}

      @impl Phantom.App
      def render(assigns) do
        ~H"<h1>Nested</h1>"
      end
    end

    test "applies root layout from plug pipeline" do
      session = Phantom.Session.new("test")
      result = LayoutApp.__phantom_app__(%{}, session)

      html = app_html(result)
      assert html =~ "<!DOCTYPE html>"
      assert html =~ "<title>Layout Test</title>"
      assert html =~ "<h1>Content inside layout</h1>"
    end

    test "applies both layout and root layout" do
      session = Phantom.Session.new("test")
      result = BothLayoutsApp.__phantom_app__(%{}, session)

      html = app_html(result)
      assert html =~ "<!DOCTYPE html>"
      assert html =~ ~s(<main class="app">)
      assert html =~ "<h1>Nested</h1>"
    end

    test "no layout when none configured" do
      session = Phantom.Session.new("test")
      result = SimpleApp.__phantom_app__(%{}, session)

      assert app_html(result) == "<h1>Plain HTML</h1>"
    end
  end

  describe "to_html/1" do
    test "passes through binary strings" do
      assert Phantom.App.to_html("<h1>Hello</h1>") == "<h1>Hello</h1>"
    end

    test "converts iodata to binary" do
      assert Phantom.App.to_html(["<h1>", "Hello", "</h1>"]) == "<h1>Hello</h1>"
    end
  end

  describe "tool app: integration" do
    defmodule AppModuleRouter do
      use Phantom.Router,
        name: "AppModuleTest",
        vsn: "1.0"

      @description "Dashboard app"
      tool :dashboard, app: MountApp
      def dashboard(_params, session), do: {:reply, Phantom.Tool.text("ok"), session}
    end

    test "tool with app: creates resource template" do
      info = AppModuleRouter.__phantom__(:info)
      template = Enum.find(info.resource_templates, &(&1.name == "dashboard"))

      assert template
      assert template.handler == MountApp
      assert template.function == :__phantom_app__
      assert template.scheme == "ui"
      assert template.mime_type == "text/html;profile=mcp-app"
    end

    test "tool with app: sets _meta.ui.resourceUri" do
      info = AppModuleRouter.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "dashboard"))

      assert tool.ui.resource_uri == "ui:///dashboard"
    end
  end
end

defmodule Phantom.App.CSPTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Phantom.App.CSP

  describe "build/1" do
    test "builds restrictive default CSP when no options given" do
      csp = CSP.build([])

      assert csp =~ "default-src 'none'"
      assert csp =~ "script-src 'self' 'unsafe-inline'"
      assert csp =~ "style-src 'self' 'unsafe-inline'"
      assert csp =~ "img-src 'self' data:"
      assert csp =~ "media-src 'self' data:"
      assert csp =~ "connect-src 'none'"
    end

    test "adds connect_domains to connect-src" do
      csp = CSP.build(connect_domains: ["https://api.example.com", "https://ws.example.com"])

      assert csp =~ "connect-src 'self' https://api.example.com https://ws.example.com"
    end

    test "adds resource_domains to script/img/style/font/media-src" do
      csp = CSP.build(resource_domains: ["https://cdn.example.com"])

      assert csp =~ "script-src 'self' 'unsafe-inline' https://cdn.example.com"
      assert csp =~ "style-src 'self' 'unsafe-inline' https://cdn.example.com"
      assert csp =~ "img-src 'self' data: https://cdn.example.com"
      assert csp =~ "font-src 'self' https://cdn.example.com"
      assert csp =~ "media-src 'self' data: https://cdn.example.com"
    end

    test "adds frame_domains to frame-src" do
      csp = CSP.build(frame_domains: ["https://embed.example.com"])

      assert csp =~ "frame-src https://embed.example.com"
    end

    test "adds base_uri_domains to base-uri" do
      csp = CSP.build(base_uri_domains: ["https://base.example.com"])

      assert csp =~ "base-uri https://base.example.com"
    end

    test "combines multiple domain types" do
      csp =
        CSP.build(
          connect_domains: ["https://api.example.com"],
          resource_domains: ["https://cdn.example.com"],
          frame_domains: ["https://embed.example.com"]
        )

      assert csp =~ "connect-src 'self' https://api.example.com"
      assert csp =~ "script-src 'self' 'unsafe-inline' https://cdn.example.com"
      assert csp =~ "frame-src https://embed.example.com"
    end
  end

  describe "build_from_ui/1" do
    test "builds CSP from a Phantom.UI struct" do
      ui =
        Phantom.UI.build(
          resource_uri: "ui:///app",
          connect_domains: ["https://api.example.com"],
          resource_domains: ["https://cdn.example.com"]
        )

      csp = CSP.build_from_ui(ui)

      assert csp =~ "connect-src 'self' https://api.example.com"
      assert csp =~ "script-src 'self' 'unsafe-inline' https://cdn.example.com"
    end

    test "returns restrictive default for nil" do
      csp = CSP.build_from_ui(nil)
      assert csp =~ "default-src 'none'"
    end
  end

  describe "put_content_security_policy/2 plug" do
    test "sets Content-Security-Policy header" do
      conn =
        conn(:get, "/")
        |> CSP.put_content_security_policy(connect_domains: ["https://api.example.com"])

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src 'self' https://api.example.com"
    end

    test "sets restrictive default when no options" do
      conn =
        conn(:get, "/")
        |> CSP.put_content_security_policy([])

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"
    end
  end

  describe "call/2 stores CSP metadata in conn.private" do
    test "stores CSP domains in conn.private[:phantom_ui_csp]" do
      conn =
        conn(:get, "/")
        |> CSP.call(CSP.init(connect_domains: ["https://api.example.com"]))

      assert %{connectDomains: ["https://api.example.com"]} = conn.private[:phantom_ui_csp]
    end

    test "returns nil when no CSP domains" do
      conn =
        conn(:get, "/")
        |> CSP.call(CSP.init([]))

      assert conn.private[:phantom_ui_csp] == nil
    end

    test "ignores non-CSP options" do
      conn =
        conn(:get, "/")
        |> CSP.call(CSP.init(permissions: [:camera], domain: "example.com"))

      assert conn.private[:phantom_ui_csp] == nil
    end
  end
end

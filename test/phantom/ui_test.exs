defmodule Phantom.UITest do
  use ExUnit.Case, async: true

  alias Phantom.UI

  describe "build/1" do
    test "returns nil when no UI attrs present" do
      assert UI.build([]) == nil
      assert UI.build(%{}) == nil
    end

    test "builds from keyword list with resource_uri" do
      ui = UI.build(resource_uri: "ui:///dashboard")

      assert %UI{} = ui
      assert ui.resource_uri == "ui:///dashboard"
      assert ui.visibility == [:model, :app]
    end

    test "builds from map" do
      ui = UI.build(%{resource_uri: "ui:///app", visibility: [:app]})

      assert ui.resource_uri == "ui:///app"
      assert ui.visibility == [:app]
    end

    test "builds with CSP domains" do
      ui =
        UI.build(
          resource_uri: "ui:///app",
          connect_domains: ["https://api.example.com"],
          resource_domains: ["https://cdn.example.com"],
          frame_domains: ["https://embed.example.com"],
          base_uri_domains: ["https://base.example.com"]
        )

      assert ui.connect_domains == ["https://api.example.com"]
      assert ui.resource_domains == ["https://cdn.example.com"]
      assert ui.frame_domains == ["https://embed.example.com"]
      assert ui.base_uri_domains == ["https://base.example.com"]
    end

    test "builds with permissions" do
      ui =
        UI.build(resource_uri: "ui:///app", permissions: [:camera, :microphone, :clipboard_write])

      assert ui.permissions == [:camera, :microphone, :clipboard_write]
    end

    test "builds with domain and prefers_border" do
      ui = UI.build(resource_uri: "ui:///app", domain: "example.com", prefers_border: true)

      assert ui.domain == "example.com"
      assert ui.prefers_border == true
    end

    test "raises on invalid visibility values" do
      assert_raise ArgumentError, ~r/invalid visibility values: \[:unknown\]/, fn ->
        UI.build(resource_uri: "ui:///app", visibility: [:unknown])
      end
    end

    test "raises on mixed valid and invalid visibility" do
      assert_raise ArgumentError, ~r/invalid visibility values: \[:nope\]/, fn ->
        UI.build(resource_uri: "ui:///app", visibility: [:model, :nope])
      end
    end
  end

  describe "to_tool_meta/1" do
    test "returns nil for nil" do
      assert UI.to_tool_meta(nil) == nil
    end

    test "returns _meta map with resourceUri and visibility as strings" do
      ui = UI.build(resource_uri: "ui:///dashboard", visibility: [:model, :app])

      assert UI.to_tool_meta(ui) == %{
               ui: %{
                 resourceUri: "ui:///dashboard",
                 visibility: ["model", "app"]
               }
             }
    end

    test "returns app-only visibility as string" do
      ui = UI.build(resource_uri: "ui:///app", visibility: [:app])

      assert %{ui: %{visibility: ["app"]}} = UI.to_tool_meta(ui)
    end
  end

  describe "to_resource_meta/1" do
    test "returns nil for nil" do
      assert UI.to_resource_meta(nil) == nil
    end

    test "returns nil when no resource-side metadata" do
      ui = UI.build(resource_uri: "ui:///app")
      assert UI.to_resource_meta(ui) == nil
    end

    test "returns _meta map with CSP domains" do
      ui =
        UI.build(
          resource_uri: "ui:///app",
          connect_domains: ["https://api.example.com"],
          resource_domains: ["https://cdn.example.com"]
        )

      meta = UI.to_resource_meta(ui)

      assert %{ui: %{csp: csp}} = meta
      assert csp.connectDomains == ["https://api.example.com"]
      assert csp.resourceDomains == ["https://cdn.example.com"]
    end

    test "returns _meta map with permissions" do
      ui = UI.build(resource_uri: "ui:///app", permissions: [:camera, :geolocation])

      meta = UI.to_resource_meta(ui)

      assert %{ui: %{permissions: permissions}} = meta
      assert permissions == %{camera: %{}, geolocation: %{}}
    end

    test "returns _meta with domain and prefers_border" do
      ui = UI.build(resource_uri: "ui:///app", domain: "example.com", prefers_border: true)

      meta = UI.to_resource_meta(ui)

      assert %{ui: %{domain: "example.com", prefersBorder: true}} = meta
    end

    test "omits nil CSP and permission fields" do
      ui = UI.build(resource_uri: "ui:///app", connect_domains: ["https://api.example.com"])

      meta = UI.to_resource_meta(ui)

      assert %{ui: ui_meta} = meta
      assert Map.has_key?(ui_meta, :csp)
      refute Map.has_key?(ui_meta, :permissions)
      refute Map.has_key?(ui_meta, :domain)
      refute Map.has_key?(ui_meta, :prefersBorder)
    end
  end

  describe "model_visible?/1" do
    test "returns true for tools without UI" do
      tool = Phantom.Tool.build(name: "basic", handler: __MODULE__, function: :noop)
      assert UI.model_visible?(tool) == true
    end

    test "returns true when visibility includes :model" do
      tool =
        Phantom.Tool.build(
          name: "ui_tool",
          handler: __MODULE__,
          function: :noop,
          ui: [resource_uri: "ui:///app", visibility: [:model, :app]]
        )

      assert UI.model_visible?(tool) == true
    end

    test "returns false when visibility is app-only" do
      tool =
        Phantom.Tool.build(
          name: "app_tool",
          handler: __MODULE__,
          function: :noop,
          ui: [resource_uri: "ui:///app", visibility: [:app]]
        )

      assert UI.model_visible?(tool) == false
    end
  end
end

defmodule Phantom.Tool.UITest do
  use ExUnit.Case, async: true

  alias Phantom.Tool
  alias Phantom.UI

  describe "build/1 with UI attrs" do
    test "builds tool without UI" do
      tool =
        Tool.build(
          name: "basic",
          handler: __MODULE__,
          function: :noop,
          description: "A basic tool"
        )

      assert tool.ui == nil
    end

    test "builds tool with UI keyword list" do
      tool =
        Tool.build(
          name: "ui_tool",
          handler: __MODULE__,
          function: :noop,
          description: "A UI tool",
          ui: [resource_uri: "ui:///dashboard", visibility: ["model", "app"]]
        )

      assert %UI{} = tool.ui
      assert tool.ui.resource_uri == "ui:///dashboard"
      assert tool.ui.visibility == [:model, :app]
    end

    test "builds tool with app-only visibility" do
      tool =
        Tool.build(
          name: "app_tool",
          handler: __MODULE__,
          function: :noop,
          description: "An app-only tool",
          ui: [resource_uri: "ui:///app", visibility: ["app"]]
        )

      assert tool.ui.visibility == [:app]
    end
  end

  describe "to_json/1 with UI" do
    test "omits _meta when no UI" do
      tool =
        Tool.build(
          name: "basic",
          handler: __MODULE__,
          function: :noop,
          description: "A basic tool"
        )

      json = Tool.to_json(tool)
      refute Map.has_key?(json, :_meta)
    end

    test "includes _meta.ui with resourceUri and visibility" do
      tool =
        Tool.build(
          name: "ui_tool",
          handler: __MODULE__,
          function: :noop,
          description: "A UI tool",
          ui: [resource_uri: "ui:///dashboard", visibility: [:model, :app]]
        )

      json = Tool.to_json(tool)

      assert %{_meta: %{ui: ui_meta}} = json
      assert ui_meta.resourceUri == "ui:///dashboard"
      assert ui_meta.visibility == ["model", "app"]
    end

    test "includes _meta.ui for app-only tools" do
      tool =
        Tool.build(
          name: "app_tool",
          handler: __MODULE__,
          function: :noop,
          description: "An app-only tool",
          ui: [resource_uri: "ui:///app", visibility: ["app"]]
        )

      json = Tool.to_json(tool)

      assert %{_meta: %{ui: %{visibility: ["app"]}}} = json
    end
  end
end

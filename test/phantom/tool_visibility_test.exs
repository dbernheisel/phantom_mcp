defmodule Phantom.Tool.VisibilityTest do
  use ExUnit.Case, async: false

  import Phantom.TestDispatcher

  describe "tools/list visibility filtering" do
    setup do
      Phantom.Cache.register(Test.MCP.Router)
      :ok
    end

    test "app-only tools are excluded from tools/list" do
      Phantom.Cache.add_tool(Test.MCP.Router, %{
        name: "vis_app_only_tool",
        handler: Test.MCP.Router,
        function: :echo_tool,
        description: "Only callable from the app",
        ui: [resource_uri: "ui:///test-app", visibility: [:app]]
      })

      request_tool_list()

      assert_receive {:response, 1, "message", response}
      tool_names = Enum.map(response.result.tools, & &1.name)
      refute "vis_app_only_tool" in tool_names
    end

    test "model+app tools are included in tools/list with _meta.ui" do
      Phantom.Cache.add_tool(Test.MCP.Router, %{
        name: "vis_model_app_tool",
        handler: Test.MCP.Router,
        function: :echo_tool,
        description: "Visible to both model and app",
        ui: [resource_uri: "ui:///test-app", visibility: [:model, :app]]
      })

      request_tool_list()

      assert_receive {:response, 1, "message", response}
      tool = Enum.find(response.result.tools, &(&1.name == "vis_model_app_tool"))
      assert tool, "vis_model_app_tool should be in the tools list"
      assert tool._meta.ui.resourceUri == "ui:///test-app"
      assert tool._meta.ui.visibility == ["model", "app"]
    end

    test "tools without UI are always included" do
      request_tool_list()

      assert_receive {:response, 1, "message", response}
      tool_names = Enum.map(response.result.tools, & &1.name)
      assert "echo_tool" in tool_names
    end
  end
end

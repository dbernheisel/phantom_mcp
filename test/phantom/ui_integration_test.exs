defmodule Phantom.UI.IntegrationTest do
  use ExUnit.Case, async: false

  import Phantom.TestDispatcher

  describe "full MCP Apps flow" do
    setup do
      Phantom.Cache.register(Test.MCP.Router)

      # Add a model+app tool linked to a UI resource
      Phantom.Cache.add_tool(Test.MCP.Router, %{
        name: "integ_dashboard_refresh",
        handler: Test.MCP.Router,
        function: :echo_tool,
        description: "Refresh dashboard data",
        ui: [resource_uri: "ui:///dashboard", visibility: ["model", "app"]]
      })

      # Add an app-only tool (should not appear in tools/list)
      Phantom.Cache.add_tool(Test.MCP.Router, %{
        name: "integ_app_submit_form",
        handler: Test.MCP.Router,
        function: :echo_tool,
        description: "Submit form from dashboard",
        ui: [resource_uri: "ui:///dashboard", visibility: ["app"]]
      })

      :ok
    end

    test "tools/list includes model-visible UI tools with _meta, excludes app-only" do
      request_tool_list()

      assert_receive {:response, 1, "message", response}
      tools = response.result.tools
      tool_names = Enum.map(tools, & &1.name)

      # Model+app tool is included
      assert "integ_dashboard_refresh" in tool_names

      # App-only tool is excluded
      refute "integ_app_submit_form" in tool_names

      # UI tool has _meta.ui
      dashboard_tool = Enum.find(tools, &(&1.name == "integ_dashboard_refresh"))
      assert dashboard_tool._meta.ui.resourceUri == "ui:///dashboard"
      assert dashboard_tool._meta.ui.visibility == ["model", "app"]
    end

    test "tools/call works for app-only tool" do
      request_tool("integ_app_submit_form", %{"message" => "form data"})

      assert_receive {:response, 1, "message", response}
      assert response.result
      refute response[:error]
    end

    test "regular tools without UI have no _meta" do
      request_tool_list()

      assert_receive {:response, 1, "message", response}
      echo_tool = Enum.find(response.result.tools, &(&1.name == "echo_tool"))
      assert echo_tool
      refute Map.has_key?(echo_tool, :_meta)
    end
  end
end

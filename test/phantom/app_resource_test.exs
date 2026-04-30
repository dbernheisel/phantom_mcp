defmodule Phantom.AppResourceTest do
  use ExUnit.Case, async: true

  defmodule DashboardApp do
    use Phantom.App

    @impl true
    def render(_assigns), do: "<h1>Dashboard</h1>"
  end

  defmodule FunctionHandlerRouter do
    use Phantom.Router, name: "FunctionHandlerTest", vsn: "1.0"

    @description "Tool with an app"
    tool :dashboard, app: DashboardApp
    def dashboard(_params, session), do: {:reply, Phantom.Tool.text("ok"), session}
  end

  defmodule ToolWithSchemaRouter do
    use Phantom.Router, name: "ToolWithSchemaTest", vsn: "1.0"

    @description "Tool with app and input schema"
    tool :search, app: DashboardApp do
      field :query, :string, required: true
    end

    def search(_params, session), do: {:reply, Phantom.Tool.text("ok"), session}
  end

  describe "tool with app: option" do
    test "creates both tool and ui:// resource template" do
      info = FunctionHandlerRouter.__phantom__(:info)

      tool = Enum.find(info.tools, &(&1.name == "dashboard"))
      assert tool
      assert tool.ui
      assert tool.ui.resource_uri == "ui:///dashboard"

      template = Enum.find(info.resource_templates, &(&1.name == "dashboard"))
      assert template
      assert template.scheme == "ui"
      assert template.mime_type == "text/html;profile=mcp-app"
      assert template.handler == DashboardApp
      assert template.function == :__phantom_app__
    end

    test "tool description comes from @description" do
      info = FunctionHandlerRouter.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "dashboard"))
      assert tool.description == "Tool with an app"
    end

    test "tool to_json includes _meta.ui.resourceUri" do
      info = FunctionHandlerRouter.__phantom__(:info)
      tool = Enum.find(info.tools, &(&1.name == "dashboard"))
      json = Phantom.Tool.to_json(tool)

      assert %{_meta: %{ui: %{resourceUri: "ui:///dashboard"}}} = json
    end

    test "works with input schema do block" do
      info = ToolWithSchemaRouter.__phantom__(:info)

      tool = Enum.find(info.tools, &(&1.name == "search"))
      assert tool
      assert tool.ui.resource_uri == "ui:///search"
      assert tool.input_schema

      template = Enum.find(info.resource_templates, &(&1.name == "search"))
      assert template
      assert template.handler == DashboardApp
    end
  end

  describe "resource macro rejects ui:// scheme" do
    test "raises when resource uses ui:// scheme" do
      assert_raise RuntimeError, ~r/ui:\/\/ scheme is reserved/, fn ->
        defmodule BadRouter do
          use Phantom.Router, name: "Bad", vsn: "1.0"
          resource "ui:///foo", :handler, description: "should fail"
          def handler(_p, s), do: {:reply, %{}, s}
        end
      end
    end
  end
end

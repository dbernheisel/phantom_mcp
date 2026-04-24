defmodule Phantom.UI.ResourceMetaTest do
  use ExUnit.Case, async: true

  alias Phantom.ResourceTemplate

  describe "ResourceTemplate.to_json/1 with UI metadata" do
    test "includes _meta.ui when UI metadata present in meta" do
      template =
        ResourceTemplate.build(
          uri: "ui:///test-app",
          handler: __MODULE__,
          function: :noop,
          router: __MODULE__,
          description: "Test app",
          mime_type: "text/html;profile=mcp-app",
          meta: %{
            file: "test.ex",
            line: 1,
            ui:
              Phantom.UI.build(
                connect_domains: ["https://api.example.com"],
                permissions: [:camera],
                prefers_border: true
              )
          }
        )

      json = ResourceTemplate.to_json(template)

      assert %{_meta: %{ui: ui_meta}} = json
      assert %{csp: %{connectDomains: ["https://api.example.com"]}} = ui_meta
      assert %{permissions: %{camera: %{}}} = ui_meta
      assert ui_meta.prefersBorder == true
    end

    test "omits _meta when no UI metadata in meta" do
      template =
        ResourceTemplate.build(
          uri: "test:///resource",
          handler: __MODULE__,
          function: :noop,
          router: __MODULE__,
          description: "Regular resource",
          mime_type: "text/plain"
        )

      json = ResourceTemplate.to_json(template)

      refute Map.has_key?(json, :_meta)
    end

    test "omits _meta when meta has only file/line" do
      template =
        ResourceTemplate.build(
          uri: "test:///resource",
          handler: __MODULE__,
          function: :noop,
          router: __MODULE__,
          description: "Regular resource",
          mime_type: "text/plain",
          meta: %{file: "test.ex", line: 1}
        )

      json = ResourceTemplate.to_json(template)

      refute Map.has_key?(json, :_meta)
    end
  end

  describe "ResourcePlug _meta injection" do
    test "resource response includes _meta.ui for UI resource" do
      ui = Phantom.UI.build(connect_domains: ["https://api.example.com"], permissions: [:camera])
      spec = %{meta: %{ui: ui}}
      request = %Phantom.Request{id: 1, spec: spec}
      session = Phantom.Session.new("test", request: request)

      result = {:reply, %{text: "<html>test</html>"}, session}

      {:reply, response, _session} =
        Phantom.Request.resource_response(result, "ui:///test-app", session)

      assert %{_meta: %{ui: ui_meta}} = response
      assert %{csp: %{connectDomains: ["https://api.example.com"]}} = ui_meta
    end

    test "resource response omits _meta for non-UI resource" do
      spec = %{meta: %{file: "test.ex", line: 1}}
      request = %Phantom.Request{id: 1, spec: spec}
      session = Phantom.Session.new("test", request: request)

      result = {:reply, %{text: "hello"}, session}

      {:reply, response, _session} =
        Phantom.Request.resource_response(result, "test:///resource", session)

      refute Map.has_key?(response, :_meta)
    end
  end

  def noop(_params, session), do: {:reply, %{}, session}
end

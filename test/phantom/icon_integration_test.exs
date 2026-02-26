defmodule Phantom.IconIntegrationTest do
  use ExUnit.Case

  alias Phantom.{Tool, Prompt, ResourceTemplate}

  describe "Tool with icons" do
    test "to_json includes icons when present" do
      tool =
        Tool.build(%{
          name: "my_tool",
          handler: __MODULE__,
          function: :my_tool,
          description: "A tool with icons",
          icons: [
            %{src: "https://example.com/tool.png", mime_type: "image/png", sizes: ["32x32"]}
          ]
        })

      json = Tool.to_json(tool)
      assert is_list(json[:icons])

      assert [%{src: "https://example.com/tool.png", mimeType: "image/png", sizes: ["32x32"]}] =
               json[:icons]
    end

    test "to_json omits icons when nil" do
      tool =
        Tool.build(%{
          name: "my_tool",
          handler: __MODULE__,
          function: :my_tool,
          description: "A tool without icons"
        })

      json = Tool.to_json(tool)
      refute Map.has_key?(json, :icons)
    end
  end

  describe "Prompt with icons" do
    test "to_json includes icons when present" do
      prompt =
        Prompt.build(%{
          name: "my_prompt",
          handler: __MODULE__,
          function: :my_prompt,
          description: "A prompt with icons",
          icons: [
            %{src: "https://example.com/prompt.svg", mime_type: "image/svg+xml", theme: "light"}
          ]
        })

      json = Prompt.to_json(prompt)
      assert is_list(json[:icons])

      assert [%{src: "https://example.com/prompt.svg", mimeType: "image/svg+xml", theme: "light"}] =
               json[:icons]
    end

    test "to_json omits icons when nil" do
      prompt =
        Prompt.build(%{
          name: "my_prompt",
          handler: __MODULE__,
          function: :my_prompt,
          description: "A prompt without icons"
        })

      json = Prompt.to_json(prompt)
      refute Map.has_key?(json, :icons)
    end
  end

  describe "ResourceTemplate with icons" do
    test "to_json includes icons when present" do
      resource_template =
        ResourceTemplate.build(%{
          name: "my_resource",
          handler: __MODULE__,
          function: :my_resource,
          router: __MODULE__,
          uri: "test:///resource/:id",
          description: "A resource with icons",
          icons: [
            %{src: "https://example.com/resource.png"}
          ]
        })

      json = ResourceTemplate.to_json(resource_template)
      assert is_list(json[:icons])
      assert [%{src: "https://example.com/resource.png"}] = json[:icons]
    end

    test "to_json omits icons when nil" do
      resource_template =
        ResourceTemplate.build(%{
          name: "my_resource",
          handler: __MODULE__,
          function: :my_resource,
          router: __MODULE__,
          uri: "test:///resource/:id",
          description: "A resource without icons"
        })

      json = ResourceTemplate.to_json(resource_template)
      refute Map.has_key?(json, :icons)
    end
  end

  describe "Router serverInfo with icons" do
    defmodule IconRouter do
      use Phantom.Router,
        name: "IconTest",
        vsn: "2.0",
        icons: [
          %{src: "https://example.com/server-icon.png", mime_type: "image/png", sizes: ["48x48"]},
          %{
            src: "https://example.com/server-icon-dark.svg",
            mime_type: "image/svg+xml",
            theme: "dark"
          }
        ],
        website_url: "https://example.com/docs"
    end

    test "server_info includes icons and websiteUrl" do
      session = %Phantom.Session{id: "test"}
      {:ok, info} = IconRouter.server_info(session)

      assert info.name == "IconTest"
      assert info.version == "2.0"

      assert [
               %{
                 src: "https://example.com/server-icon.png",
                 mimeType: "image/png",
                 sizes: ["48x48"]
               },
               %{
                 src: "https://example.com/server-icon-dark.svg",
                 mimeType: "image/svg+xml",
                 theme: "dark"
               }
             ] = info.icons

      assert info.websiteUrl == "https://example.com/docs"
    end

    defmodule NoIconRouter do
      use Phantom.Router,
        name: "NoIconTest",
        vsn: "1.0"
    end

    test "server_info omits icons and websiteUrl when not configured" do
      session = %Phantom.Session{id: "test"}
      {:ok, info} = NoIconRouter.server_info(session)

      assert info == %{name: "NoIconTest", version: "1.0"}
    end

    defmodule FakeEndpoint do
      def url, do: "https://myapp.example.com"
      def asset_url(path), do: url() <> path
    end

    defmodule MFAIconRouter do
      use Phantom.Router,
        name: "MFAIconTest",
        vsn: "1.0",
        icons: [
          %{
            src: {Phantom.IconIntegrationTest.FakeEndpoint, :asset_url, ["/images/icon.png"]},
            mime_type: "image/png"
          }
        ],
        website_url: {Phantom.IconIntegrationTest.FakeEndpoint, :url, []}
    end

    test "server_info resolves MFA tuples at runtime" do
      session = %Phantom.Session{id: "test"}
      {:ok, info} = MFAIconRouter.server_info(session)

      assert [%{src: "https://myapp.example.com/images/icon.png", mimeType: "image/png"}] =
               info.icons

      assert info.websiteUrl == "https://myapp.example.com"
    end
  end
end

defmodule Phantom.IconTest.FakeEndpoint do
  def url, do: "https://myapp.example.com"
  def static_url, do: "https://cdn.example.com"
  def asset_url(path), do: static_url() <> path
end

defmodule Phantom.IconTest do
  use ExUnit.Case

  alias Phantom.Icon
  alias Phantom.IconTest.FakeEndpoint

  describe "build/1" do
    test "builds an icon with only src" do
      icon = Icon.build(%{src: "https://example.com/icon.png"})
      assert %Icon{src: "https://example.com/icon.png"} = icon
      assert is_nil(icon.mime_type)
      assert is_nil(icon.sizes)
      assert is_nil(icon.theme)
    end

    test "builds an icon with all fields" do
      icon =
        Icon.build(%{
          src: "https://example.com/icon.png",
          mime_type: "image/png",
          sizes: ["48x48", "96x96"],
          theme: "dark"
        })

      assert %Icon{
               src: "https://example.com/icon.png",
               mime_type: "image/png",
               sizes: ["48x48", "96x96"],
               theme: "dark"
             } = icon
    end

    test "builds an icon with a data URI" do
      data_uri = "data:image/png;base64,iVBORw0KGgo="
      icon = Icon.build(%{src: data_uri, mime_type: "image/png"})
      assert icon.src == data_uri
    end

    test "accepts keyword list" do
      icon = Icon.build(src: "https://example.com/icon.svg", theme: "light")
      assert icon.src == "https://example.com/icon.svg"
      assert icon.theme == "light"
    end

    test "accepts an MFA tuple for src" do
      mfa = {FakeEndpoint, :asset_url, ["/images/icon.png"]}
      icon = Icon.build(%{src: mfa, mime_type: "image/png"})
      assert icon.src == mfa
    end
  end

  describe "to_json/1" do
    test "serializes icon with only src" do
      icon = Icon.build(%{src: "https://example.com/icon.png"})
      json = Icon.to_json(icon)

      assert json == %{src: "https://example.com/icon.png"}
      refute Map.has_key?(json, :mimeType)
      refute Map.has_key?(json, :sizes)
      refute Map.has_key?(json, :theme)
    end

    test "serializes icon with all fields" do
      icon =
        Icon.build(%{
          src: "https://example.com/icon.png",
          mime_type: "image/png",
          sizes: ["48x48"],
          theme: "dark"
        })

      json = Icon.to_json(icon)

      assert json == %{
               src: "https://example.com/icon.png",
               mimeType: "image/png",
               sizes: ["48x48"],
               theme: "dark"
             }
    end

    test "resolves MFA tuple in src at serialization time" do
      icon =
        Icon.build(%{
          src: {FakeEndpoint, :asset_url, ["/images/icon.png"]},
          mime_type: "image/png"
        })

      json = Icon.to_json(icon)

      assert json[:src] == "https://cdn.example.com/images/icon.png"
    end
  end

  describe "to_json_list/1" do
    test "serializes a list of icons" do
      icons = [
        Icon.build(%{src: "https://example.com/light.png", theme: "light"}),
        Icon.build(%{src: "https://example.com/dark.png", theme: "dark"})
      ]

      json_list = Icon.to_json_list(icons)

      assert [
               %{src: "https://example.com/light.png", theme: "light"},
               %{src: "https://example.com/dark.png", theme: "dark"}
             ] = json_list
    end

    test "returns nil for nil input" do
      assert is_nil(Icon.to_json_list(nil))
    end

    test "returns nil for empty list" do
      assert is_nil(Icon.to_json_list([]))
    end
  end
end

defmodule Phantom.UI.CapabilityTest do
  use ExUnit.Case, async: true

  alias Phantom.Session

  describe "ui_capability/3" do
    test "adds extensions when ui:// resource templates exist" do
      # Directly test the capability function with a mock session + cache setup
      ui_template =
        Phantom.ResourceTemplate.build(
          uri: "ui:///test-app",
          handler: __MODULE__,
          function: :noop,
          router: __MODULE__,
          description: "Test app",
          mime_type: "text/html;profile=mcp-app"
        )

      :persistent_term.put({Phantom, __MODULE__, :resource_templates}, [ui_template])

      on_exit(fn -> :persistent_term.erase({Phantom, __MODULE__, :resource_templates}) end)

      session = Session.new("test-session")

      capabilities =
        Phantom.Router.ui_capability(%{}, __MODULE__, session)

      assert %{extensions: extensions} = capabilities

      assert %{"io.modelcontextprotocol/ui" => %{mimeTypes: ["text/html;profile=mcp-app"]}} =
               extensions
    end

    test "omits extensions when no ui:// resource templates" do
      non_ui_template =
        Phantom.ResourceTemplate.build(
          uri: "test:///resource",
          handler: __MODULE__,
          function: :noop,
          router: __MODULE__,
          description: "Not UI",
          mime_type: "text/plain"
        )

      :persistent_term.put({Phantom, __MODULE__, :resource_templates}, [non_ui_template])

      on_exit(fn -> :persistent_term.erase({Phantom, __MODULE__, :resource_templates}) end)

      session = Session.new("test-session")

      capabilities =
        Phantom.Router.ui_capability(%{}, __MODULE__, session)

      refute Map.has_key?(capabilities, :extensions)
    end

    test "omits extensions when no resource templates at all" do
      :persistent_term.put({Phantom, __MODULE__, :resource_templates}, [])
      on_exit(fn -> :persistent_term.erase({Phantom, __MODULE__, :resource_templates}) end)

      session = Session.new("test-session")

      capabilities =
        Phantom.Router.ui_capability(%{}, __MODULE__, session)

      refute Map.has_key?(capabilities, :extensions)
    end
  end

  describe "client ui capability in session" do
    test "Session has :ui in client_capabilities default" do
      session = Session.new("test-session")
      assert session.client_capabilities.ui == false
    end
  end

  def noop(_params, session), do: {:reply, %{}, session}
end

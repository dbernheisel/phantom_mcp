defmodule Phantom.RouterExtensionsTest do
  use ExUnit.Case, async: true

  @client_credentials "io.modelcontextprotocol/oauth-client-credentials"

  defmodule ExtensionsRouter do
    use Phantom.Router,
      name: "Test",
      vsn: "1.0",
      extensions: %{"io.modelcontextprotocol/oauth-client-credentials" => %{}}

    def get_task(_task_id, _session), do: nil
  end

  defmodule PlainRouter do
    use Phantom.Router, name: "Test", vsn: "1.0"
  end

  setup_all do
    Phantom.Cache.register(ExtensionsRouter)
    Phantom.Cache.register(PlainRouter)
    :ok
  end

  defp dispatch(router, method, params) do
    session = Phantom.Test.build_session(router)
    request = Phantom.Test.build_request(method, params: params)
    router.dispatch_method(method, params, request, %{session | request: request})
  end

  test "server/discover advertises the router's extensions beside Phantom's own" do
    assert {:reply, %{capabilities: %{extensions: extensions}}, _} =
             dispatch(ExtensionsRouter, "server/discover", %{})

    assert extensions[@client_credentials] == %{}
    assert Map.has_key?(extensions, Phantom.Tasks.extension())
  end

  test "initialize advertises the router's extensions" do
    params = %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}

    assert {:reply, %{capabilities: %{extensions: %{@client_credentials => %{}}}}, _} =
             dispatch(ExtensionsRouter, "initialize", params)
  end

  test "a router without extensions advertises none" do
    assert {:reply, %{capabilities: capabilities}, _} =
             dispatch(PlainRouter, "server/discover", %{})

    refute Map.has_key?(capabilities, :extensions)
  end
end

defmodule Test.MCP.MinimalApp do
  @moduledoc "Minimal app — no plugs, no CSP, no mount, no layout."
  use Phantom.App

  @mcp_app_js_path Path.join(__DIR__, "js/mcp_app.js")
  @external_resource @mcp_app_js_path
  @mcp_app_js_b64 @mcp_app_js_path |> File.read!() |> Base.encode64()

  @impl true
  def render(_assigns) do
    """
    <!DOCTYPE html>
    <html>
    <head><title>Minimal</title></head>

    <script src="data:text/javascript;base64,#{@mcp_app_js_b64}"></script>
    <body><h1>Minimal App</h1><p>No CSP, no permissions, no mount override. MCP App JS SDK fails to load</p></body>
    </html>
    """
  end
end

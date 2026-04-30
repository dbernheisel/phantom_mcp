defmodule Test.MCP.SampleApp do
  @moduledoc "A sample MCP App using Phoenix layouts, components, and all CSP options."
  use Phantom.App,
    domain: "localhost",
    prefers_border: false

  use Phoenix.Component
  import Phoenix.Controller, only: [put_root_layout: 2, put_layout: 2]

  plug :put_root_layout, html: {Test.MCP.Layouts, :root}
  plug :put_layout, html: {Test.MCP.Layouts, :app}

  plug Phantom.App.CSP,
    connect_domains:
      Enum.flat_map([9832, 4000, 4001, 4002], fn port ->
        ["http://localhost:#{port}", "ws://localhost:#{port}"]
      end),
    resource_domains:
      Enum.flat_map([9832, 4000, 4001, 4002], fn port -> ["http://localhost:#{port}"] end),
    frame_domains:
      Enum.flat_map([9832, 4000, 4001, 4002], fn port -> ["http://localhost:#{port}"] end),
    base_uri_domains:
      Enum.flat_map([9832, 4000, 4001, 4002], fn port -> ["http://localhost:#{port}"] end)

  @impl Phantom.App
  def mount(params, session) do
    {:ok,
     %{
       title: "Sample MCP App",
       session_id: session.id,
       params: params,
       items: ["Alpha", "Bravo", "Charlie"],
       timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  @impl Phantom.App
  def render(assigns) do
    ~H"""
    <h1 style="color: var(--color-primary); margin-bottom: 8px;">{@title}</h1>
    <div style="color: var(--color-muted); font-size: 0.875rem; margin-bottom: 24px;">
      Session: <code>{@session_id}</code> -Rendered: <code>{@timestamp}</code>
    </div>

    <.items_section items={@items} />
    <.params_section params={@params} />
    <.permissions_section />
    <.csp_section />
    <.interactive_section session_id={@session_id} />
    """
  end

  defp items_section(assigns) do
    ~H"""
    <.section title="Items">
      <ul style="list-style: none;">
        <li
          :for={item <- @items}
          style="padding: 8px 12px; margin: 4px 0; background: var(--color-surface); border-radius: var(--radius);"
        >
          {item}
        </li>
      </ul>
    </.section>
    """
  end

  defp params_section(assigns) do
    ~H"""
    <.section title="Params">
      <pre style="background: var(--color-surface); padding: 12px; border-radius: var(--radius); font-size: 0.8rem; overflow-x: auto;">
        {JSON.encode!(@params)}
      </pre>
    </.section>
    """
  end

  defp permissions_section(assigns) do
    ~H"""
    <.section title="Permissions Requested">
      <.badge :for={perm <- ~w[camera microphone geolocation clipboard-write]}>{perm}</.badge>
    </.section>
    """
  end

  defp csp_section(assigns) do
    ~H"""
    <.section title="CSP Domains">
      <ul style="list-style: none;">
        <li
          :for={
            {label, domains} <- [
              {"connect", "http://localhost, ws://localhost"},
              {"resources", "localhost"},
              {"frames", "localhost"},
              {"base-uri", "localhost"}
            ]
          }
          style="padding: 8px 12px; margin: 4px 0; background: var(--color-surface); border-radius: var(--radius);"
        >
          <strong>{label}:</strong> {domains}
        </li>
      </ul>
    </.section>
    """
  end

  defp interactive_section(assigns) do
    ~H"""
    <.section title="Interactive">
      <div style="display: flex; gap: 8px; flex-wrap: wrap; align-items: center;">
        <input
          id="echo-input"
          type="text"
          value="Hello from the MCP App!"
          style="flex: 1; min-width: 200px; padding: 8px 10px; border: 1px solid #cbd5e1; border-radius: var(--radius); font-size: 0.875rem;"
        />
        <.button onclick="callEchoTool()">Call echo_tool</.button>
        <.button kind="secondary" onclick="listResources()">List Resources</.button>
        <.button kind="secondary" onclick="testClipboard()">Write Clipboard</.button>
      </div>
      <div
        id="output"
        style="margin-top: 12px; min-height: 40px; max-height: 240px; overflow-y: auto; padding: 8px 10px; background: var(--color-surface); border-radius: var(--radius); font-family: monospace; font-size: 0.8rem;"
      >
      </div>
    </.section>
    <script>
      const output = document.getElementById('output');
      function log(msg) {
        const line = document.createElement('div');
        line.textContent = msg;
        output.appendChild(line);
        output.scrollTop = output.scrollHeight;
      }

      // Lifecycle events from mcp_app.js
      document.addEventListener('mcp:initialized', (e) => {
        const host = e.detail?.hostInfo?.name || 'unknown';
        const caps = e.detail?.hostCapabilities || {};
        const serverCaps = Object.keys(caps).filter(k => k.startsWith('server'));
        log('[ok] initialized -host=' + host + ' -server-caps=' + (serverCaps.join(',') || 'none'));
      });
      document.addEventListener('mcp:tool-input', (e) => {
        log('[ok] tool-input: ' + JSON.stringify(e.detail));
      });
      document.addEventListener('mcp:tool-result', () => log('[ok] tool-result received'));

      // Server-call result events from mcp_app.js
      document.addEventListener('mcp:server-tool-result', (e) => {
        const { name, result } = e.detail || {};
        const text = result?.content?.[0]?.text ?? JSON.stringify(result);
        log('[ok] ' + name + ' ->' + text);
      });
      document.addEventListener('mcp:server-tool-error', (e) => {
        log('[fail] ' + e.detail.name + ' ->' + e.detail.error);
      });
      document.addEventListener('mcp:server-resources-list', (e) => {
        const count = e.detail?.result?.resources?.length || 0;
        log('[ok] resources/list ->' + count + ' resource(s)');
      });
      document.addEventListener('mcp:server-resources-error', (e) => {
        log('[fail] resources/list ->' + e.detail.error);
      });

      function callEchoTool() {
        const msg = document.getElementById('echo-input').value || 'hello';
        document.dispatchEvent(new CustomEvent('mcp:request-server-tool', {
          detail: { name: 'echo_tool', arguments: { message: msg } }
        }));
      }
      function listResources() {
        document.dispatchEvent(new CustomEvent('mcp:request-list-resources'));
      }
      function testClipboard() {
        navigator.clipboard.writeText('Hello from MCP App')
          .then(() => log('[ok] clipboard write succeeded'))
          .catch(e => log('[fail] clipboard blocked: ' + e.message));
      }

      log('app loaded -mcpApp: ' + (window.mcpApp ? 'available' : 'not in MCP host'));
    </script>
    """
  end

  # -- Shared components --

  defp section(assigns) do
    ~H"""
    <div style="margin-bottom: 24px;">
      <h2 style="font-size: 1rem; margin-bottom: 8px; border-bottom: 1px solid #e2e8f0; padding-bottom: 4px;">
        {@title}
      </h2>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :kind, :string, default: "primary"
  attr :rest, :global
  slot :inner_block, required: true

  defp button(assigns) do
    ~H"""
    <button
      style={"padding: 8px 16px; color: white; border: none; border-radius: var(--radius); cursor: pointer; font-size: 0.875rem; background: #{if @kind == "primary", do: "var(--color-primary)", else: "#64748b"};"}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp badge(assigns) do
    ~H"""
    <span style="display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.75rem; font-weight: 600; background: #dbeafe; color: #1e40af; margin: 2px;">
      {render_slot(@inner_block)}
    </span>
    """
  end
end

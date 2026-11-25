# Authentication

Phantom does not implement authentication on its own. It calls your router's
`c:Phantom.Router.connect/2` callback on each request, where you verify the
client and decide what it may use.

## OAuth

MCP applications needing authentication should investigate OAuth provider
solutions like [Oidcc](https://hex.pm/packages/oidcc),
[Boruta](https://hex.pm/packages/boruta), or
[ExOauth2Provider](https://hex.pm/packages/ex_oauth2_provider), and configure
the route to serve a discovery endpoint.

1. [MCP authentication and discovery](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
   is not handled by Phantom itself. You will need to implement OAuth2 and
   provide the discovery mechanisms as described in the specification.

2. Once the authentication flow has been completed, a request to the MCP
   router should land with an authorization header that can be received and
   verified in `c:Phantom.Router.connect/2`.

3. You may also decide to limit the available tools, prompts, or resources
   depending on your authorization rules.

For machine clients that authenticate with the OAuth `client_credentials`
grant, such as CI jobs and other services, see the
[OAuth Client Credentials](oauth_client_credentials.md) guide.

## The `connect/2` callback

`connect/2` receives the session and, over HTTP, the `Plug.Conn`. Return:

- `{:ok, session}` - the client is authenticated and authorized.
- `{:unauthorized, www_authenticate}` - the client is not authenticated. The
  map or string tells the client how to authenticate; see
  `Phantom.Plug.www_authenticate/1`.
- `{:forbidden, message}` - the client is authenticated, but may not use the
  server.
- `{:not_found, message}` - the session was terminated; the client starts a
  new one.

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0"

  alias Phantom.Session

  def connect(session, %Plug.Conn{} = conn) do
    with {:ok, user} <- MyApp.Auth.verify_bearer(conn),
         :ok <- MyApp.Auth.allowed_mcp?(user) do
      {:ok,
       session
       |> Session.assign(user: user)
       |> limit_for_plan(user.plan)}
    else
      :not_found ->
        {:unauthorized,
         %{
           method: "Bearer",
           resource_metadata: "https://myapp.com/.well-known/oauth-protected-resource"
         }}

      :not_allowed ->
        {:forbidden, "Please upgrade plan to use MCP server"}
    end
  end

  defp limit_for_plan(session, :ultra), do: session

  defp limit_for_plan(session, :basic) do
    # Allow-list by stringified name: the `name` given when defining it,
    # or the stringified function name.
    session
    |> Session.allow_tools(~w[create_question])
    |> Session.allow_resource_templates(~w[study])
  end
end
```

Handlers read what you assigned from `session.assigns`.

`Phantom.Session.allow_tools/2`, `allow_prompts/2`,
`allow_resource_templates/2`, and `allow_agents/2` limit what the session can
list and call. Skills are resource templates, so `allow_resource_templates/2`
limits them too.

## Lifecycle callbacks

There are several optional callbacks to hook into the lifecycle of the
connections:

- `c:Phantom.Router.disconnect/1` means the request has closed, not that the
  session is finished.
- `c:Phantom.Router.terminate/1` means the session has finished and the
  client doesn't intend to resume it. Phantom closes the session's streams
  but doesn't remember the session; to answer later requests with HTTP 404 as
  the spec requires, record it here and return `{:not_found, message}` from
  `c:Phantom.Router.connect/2`.

For telemetry, see `m:Phantom.Plug#module-telemetry` and
`m:Phantom.Router#module-telemetry`.

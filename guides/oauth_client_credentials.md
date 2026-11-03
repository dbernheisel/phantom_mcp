# OAuth Client Credentials

The [OAuth Client Credentials extension](https://modelcontextprotocol.io/extensions/auth/oauth-client-credentials)
(`io.modelcontextprotocol/oauth-client-credentials`) lets clients with no user
present, such as CI jobs, scheduled syncs and other services, call your MCP
server. The client gets an access token from your authorization server with
the OAuth `client_credentials` grant, then sends it as a bearer token like
any other MCP client.

Phantom doesn't issue or verify tokens. Most of the extension is between the
client and your authorization server; your router's part is checking the token
in `c:Phantom.Router.connect/2`:

| Who | Does |
|---|---|
| Your authorization server | Registers machine clients out of band and issues tokens for the `client_credentials` grant |
| Your authorization server | Lists `private_key_jwt` and/or `client_secret_basic` in `token_endpoint_auth_methods_supported`, and `token_endpoint_auth_signing_alg_values_supported` when it accepts JWTs |
| Your app | Serves the protected resource metadata that names the authorization server |
| Your router | Answers requests without a valid token with `401` and `WWW-Authenticate` |
| Your router | Verifies the token, its audience and its scopes, then limits what a machine client may use |
| Phantom | Advertises the extension when you list it in `:extensions` |

## Advertising the extension

The specification recommends advertising support in `server/discover`. List
the extension when you use `Phantom.Router`; Phantom adds it to
`capabilities.extensions` in `server/discover` and `initialize`:

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router,
    name: "MyApp",
    vsn: "1.0",
    extensions: %{"io.modelcontextprotocol/oauth-client-credentials" => %{}}
end
```

## Pointing clients at your authorization server

A client without a token gets a `401`. The `WWW-Authenticate` header names
your [protected resource metadata](https://datatracker.ietf.org/doc/html/rfc9728),
which names your authorization server. Serve the metadata outside
`Phantom.Plug`, for example in a Phoenix controller:

```elixir
# router.ex
get "/.well-known/oauth-protected-resource", MyAppWeb.OAuthMetadataController, :show

# oauth_metadata_controller.ex
def show(conn, _params) do
  json(conn, %{
    resource: "https://mcp.myapp.example/mcp",
    authorization_servers: ["https://auth.myapp.example"],
    scopes_supported: ["mcp:read", "mcp:write"]
  })
end
```

The client then reads your authorization server's metadata to learn how to
authenticate at its token endpoint. Configure that in your authorization
server, not in Phantom.

## Checking the token in `connect/2`

A client credentials token is a bearer token like any other. Verify it in
`c:Phantom.Router.connect/2` with your OAuth library: its signature, expiry,
issuer, and an audience that is this MCP server.

A token issued with the `client_credentials` grant has no user. In
[RFC 9068](https://datatracker.ietf.org/doc/html/rfc9068#section-2.2) access
tokens, `sub` is then the client's ID; other authorization servers mark it
their own way. Treat that client as its own principal, not as a user, and
allow it only what its scopes cover:

```elixir
def connect(session, conn) do
  with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
       {:ok, claims} <- MyApp.Auth.verify_access_token(token) do
    authorize(session, claims)
  else
    _ ->
      {:unauthorized,
       %{
         method: "Bearer",
         resource_metadata: "https://mcp.myapp.example/.well-known/oauth-protected-resource"
       }}
  end
end

# A user signed in through the authorization code flow.
defp authorize(session, %{"sub" => sub, "client_id" => client_id})
     when sub != client_id do
  {:ok, Phantom.Session.assign(session, user: MyApp.Accounts.get_user!(sub))}
end

# A machine client: no user, and only the tools its scopes allow.
defp authorize(session, %{"client_id" => client_id, "scope" => scope}) do
  scopes = String.split(scope)

  if "mcp:read" in scopes do
    {:ok,
     session
     |> Phantom.Session.assign(client_id: client_id)
     |> Phantom.Session.allow_tools(MyApp.MCP.tools_for_scopes(scopes))}
  else
    {:forbidden, "This client may not use the MCP server"}
  end
end
```

Phantom calls `connect/2` on every request, so an expired or revoked token
stops working on the next request. Clients refresh their tokens themselves.

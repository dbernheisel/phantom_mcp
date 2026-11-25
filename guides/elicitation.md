# Elicitation

Elicitation lets a handler ask the user for input before it answers, such as
a confirmation, a missing field, or a sign-in on a page you host. Phantom
offers two shapes, picked by how you want to structure the handler, and both
work under every protocol version.

See `Phantom.Elicit` for what each protocol version sends, and
`Phantom.Session.elicit/3` for every option.

## Inline blocking

The handler awaits the response in place and continues inline:

```elixir
def my_tool(params, session) do
  case Phantom.Session.elicit(session, @elicit_name, await: true) do
    {:ok, %{"action" => "accept", "content" => content}} ->
      {:reply, Tool.text("Hello #{content["name"]}"), session}

    {:ok, _rejected} ->
      {:reply, Tool.error("Rejected"), session}

    :not_supported ->
      {:reply, Tool.text("Hello stranger"), session}
  end
end
```

Under MCP `2026-07-28` the call is answered with an `input_required` result
while the calling process waits; the client's follow-up call, on any node in
the cluster, resumes it and receives the tool's response. The process lives on
the node that started it, so a follow-up after that node restarts, or after
`:timeout` (default 5 minutes), gets an error. The same holds for
`Session.elicit/2` called from a process the handler started, such as a `Task`.

## Re-entry

Call `Phantom.Session.elicit/3` without `:await`, and pass `:state`, to get
the re-entry pattern: the handler is invoked again with `session.state`
populated on continuation. The same source works under both protocols:

```elixir
use Phantom.Router,
  name: "MyApp",
  secret_key_base: {Application, :fetch_env!, [:my_app, :mcp_secret_key_base]},
  request_state_salt: "myapp request_state v1"

tool :delete_file, description: "Delete a file after confirming with the user" do
  field :path, :string, required: true
end

# Resume clause — runs on the second invocation under either protocol
def delete_file(
      %{"confirm" => "yes"},
      %Phantom.Session{state: %{step: :confirming, path: path}} = session
    ) do
  File.rm!(path)
  {:reply, Tool.text("Deleted #{path}"), session}
end

def delete_file(%{"confirm" => _}, session),
  do: {:reply, Tool.text("Cancelled"), session}

# First-call clause — ask the user
def delete_file(%{"path" => path}, session) do
  {:noreply,
   Phantom.Session.elicit(
     session,
     Phantom.Elicit.form(%{
       message: "Really delete #{path}?",
       requested_schema: [
         %{name: "confirm", type: :enum, enum: ["yes", "no"], required: true}
       ]
     }),
     state: %{step: :confirming, path: path}
   )}
end
```

Under `2026-07-28` the call returns an `input_required` result with an
encrypted `requestState` blob; any node can serve the follow-up. Under
legacy protocols Phantom performs the SSE `elicitation/create` round-trip
and re-invokes the handler — same handler code, no `if protocol_version`
check.

### Encrypting request state

`:secret_key_base` and `:request_state_salt` are both required for
`2026-07-28`. Phantom encrypts the `requestState` blob with `Plug.Crypto`
(no Phoenix dependency), using the salt to derive a domain-specific key.
Each node serving the same router must share both values; clients can hop
nodes freely.

`:secret_key_base` can be a `{module, function, args}` tuple, called each
time Phantom needs the key, so a release can set it in `config/runtime.exs`
instead of compiling it into the router:

```elixir
# config/runtime.exs
config :my_app, mcp_secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
```

With Phoenix, `{MyAppWeb.Endpoint, :config, [:secret_key_base]}` reuses the
endpoint's key.

## Sending the user to a URL

URL elicitation sends the user to a page you host, such as a sign-in or
payment flow, instead of a form in the client. The client must declare
`elicitation: %{"url" => %{}}`; otherwise the call returns `:not_supported`.

The client's `accept` only means the user agreed to open the URL, not that
they finished. Keep your own record of the flow, tied to the signed-in user,
and check it. The simplest shape returns `{:elicitation_required, ...}` until
the record says the user is done; the client opens the URL and calls the tool
again:

```elixir
def connect_account(_params, session) do
  user = session.assigns.user

  if MyApp.Accounts.connected?(user) do
    {:reply, Tool.text("Connected"), session}
  else
    elicitation_id = UUIDv7.generate()
    MyApp.Accounts.start_connect(user, elicitation_id)

    {:elicitation_required,
     [
       Phantom.Elicit.url(%{
         message: "Connect your account",
         url: "https://myapp.example/connect/#{elicitation_id}",
         elicitation_id: elicitation_id
       })
     ]}
  end
end
```

The page must check that the signed-in user is the one who started the flow.
Otherwise someone could send their link to another user and have that user
connect an account for them:

```elixir
def connect(conn, %{"elicitation_id" => elicitation_id}) do
  case MyApp.Accounts.get_connect(elicitation_id) do
    %{user_id: user_id} = flow when user_id == conn.assigns.current_user.id ->
      MyApp.Accounts.complete_connect(flow)
      render(conn, :connected)

    _ ->
      conn |> put_status(:forbidden) |> render(:wrong_user)
  end
end
```

## Testing

`Phantom.Test.expect_elicit/1` answers elicitations in tests; see the
[Testing](testing.md) guide.

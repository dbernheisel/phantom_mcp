defmodule Phantom.RequestState do
  @moduledoc """
  Encode and decode the opaque `requestState` blob that powers multi-round-trip
  tool calls under MCP `2026-07-28`.

  Under the stateless core, a tool that needs additional client input returns
  an `inputRequired` result containing a `requestState` value. The client
  echoes that value back on the follow-up `tools/call`, and any server node
  can pick up where the previous one left off — no sticky session, no
  cross-node state replication.

  The blob is authenticated-encrypted with `Plug.Crypto` (AES-256-GCM over an
  HKDF-derived key, the same construction `Phoenix.Token` uses). Clients
  cannot tamper with the contents, read them, or replay them past the
  configured `max_age`.

  ## Configuration

  Encoding requires two values, both set on the router:

  - `:secret_key_base` — a high-entropy binary of at least 64 bytes (typically
    the same one your Phoenix endpoint uses).
  - `:request_state_salt` — a string used as the HKDF salt to derive a key
    specifically for `requestState` blobs. Doesn't need to be secret, but
    must be stable; rotating it invalidates all in-flight blobs.

  ```elixir
  use Phantom.Router,
    name: "MyApp",
    secret_key_base: Application.compile_env(:my_app, :secret_key_base),
    request_state_salt: "myapp request_state v1"
  ```
  """

  # 24 hours
  @default_max_age 86_400

  @doc """
  Encrypts and signs `term` so it can travel through the client as a
  `requestState` value.

  - `secret_key_base` must be a binary of at least 64 bytes.
  - `salt` is a stable string the router carries (see module doc).
  """
  def encode(term, secret_key_base, salt)
      when is_binary(secret_key_base) and byte_size(secret_key_base) >= 64 and is_binary(salt) do
    Plug.Crypto.encrypt(secret_key_base, salt, term)
  end

  @doc """
  Decrypts and verifies a `requestState` token.

  Returns `{:ok, term}` on success, `{:error, :expired}` if the token is
  older than `max_age` seconds (default: #{@default_max_age}), or
  `{:error, :invalid}` if the token has been tampered with, signed with a
  different secret, or is otherwise unparseable.
  """
  def decode(token, secret_key_base, salt, opts \\ [])
      when is_binary(token) and is_binary(salt) do
    max_age = Keyword.get(opts, :max_age, @default_max_age)

    case Plug.Crypto.decrypt(secret_key_base, salt, token, max_age: max_age) do
      {:ok, term} -> {:ok, term}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end
end

defmodule Phantom.ProtocolVersion do
  @moduledoc """
  Supported MCP protocol versions and per-version dispatch mode.

  Phantom branches between the legacy stateful model — initialize handshake,
  `mcp-session-id` header, persistent SSE GET stream — and the new stateless
  core (`2026-07-28`) where each request is self-contained and carries its
  capabilities and resumable state in `_meta`.
  """

  @latest "2026-07-28"

  @supported ~w[
    2024-11-05
    2025-03-26
    2025-06-18
    2025-11-25
    2026-07-28
  ]

  @stateless_core ~w[2026-07-28]

  @doc "The newest protocol version Phantom advertises."
  def latest, do: @latest

  @doc "All protocol versions Phantom supports, oldest first."
  def supported, do: @supported

  @doc "Whether the given version string is recognized by Phantom."
  def supported?(version), do: version in @supported

  @doc """
  Dispatch mode for a protocol version.

  Returns `:legacy` for versions that use the initialize handshake and
  `mcp-session-id` header, `:stateless_core` for `2026-07-28` and later, and
  `:unsupported` for anything Phantom does not recognize.
  """
  def mode(version) when version in @stateless_core, do: :stateless_core
  def mode(version) when version in @supported, do: :legacy
  def mode(_), do: :unsupported
end

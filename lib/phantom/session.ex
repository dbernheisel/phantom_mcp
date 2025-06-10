defmodule Phantom.Session do
  @moduledoc """
  Represents the state of the MCP session. This is the state across the conversation
  and is the bridge between the various transports (HTTP, stdio) to persistence,
  even if stateless.
  """

  @enforce_keys [:id]
  defstruct [
    :id,
    :router,
    :transport_pid,
    :tools,
    :resource_templates,
    :prompts,
    assigns: %{},
    meta: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          router: module(),
          transport_pid: pid() | nil,
          tools: [Phantom.Tool.t()],
          resource_templates: [Phantom.ResourceTemplate.t()],
          prompts: [Phantom.Prompt.t()],
          assigns: map(),
          meta: map()
        }

  @spec new(String.t() | nil, Plug.Conn.t(), Keyword.t() | map) :: t()
  def new(session_id, %Plug.Conn{}, opts \\ []) do
    struct!(__MODULE__,
      id: session_id || UUIDv7.generate(),
      router: opts[:router],
      tools: opts[:tools],
      resource_templates: opts[:resource_templates],
      prompts: opts[:prompts]
    )
  end

  @spec assign(t(), atom(), any()) :: t()
  def assign(session, key, value) do
    %{session | assigns: Map.put(session.assigns, key, value)}
  end

  @spec assign(t(), map()) :: t()
  def assign(session, map) do
    %{session | assigns: Map.merge(session.assigns, Map.new(map))}
  end
end

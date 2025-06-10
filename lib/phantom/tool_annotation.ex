defmodule Phantom.Tool.Annotation do
  @moduledoc """
  Tool annotations provide additional metadata about a
  tool’s behavior, helping clients understand how to present
  and manage tools. These annotations are hints that describe
  the nature and impact of a tool, but should not be relied
  upon for security decisions

  - `:title` A human-readable title for the tool, useful for UI display
  - `:read_only_hint` If true, indicates the tool does not modify its environment
  - `:destructive_hint` If true, the tool may perform destructive updates (only meaningful when `:read_only_hint` is false)
  - `:idempotent_hint` If true, calling the tool repeatedly with the same arguments has no additional effect (only meaningful when readOnlyHint is false)
  - `:open_world_hint` If true, the tool may interact with an “open world” of external entities

  https://modelcontextprotocol.io/docs/concepts/tools#tool-annotations
  """

  import Phantom.Utils

  defstruct [
    :title,
    :idempotent_hint,
    :destructive_hint,
    :read_only_hint,
    :open_world_hint
  ]

  @type t :: %__MODULE__{
          title: String.t(),
          idempotent_hint: boolean(),
          destructive_hint: boolean(),
          read_only_hint: boolean(),
          open_world_hint: boolean()
        }

  @type json :: %{
          optional(:title) => String.t(),
          optional(:idempotentHint) => boolean(),
          optional(:destructiveHint) => boolean(),
          optional(:readOnlyHint) => boolean(),
          optional(:openWorldHint) => boolean()
        }

  def build(attrs \\ []) do
    attrs =
      Enum.reduce(attrs, %{}, fn
        {:idempotent, v}, acc -> Map.put(acc, :idempotent_hint, v)
        {:destructive, v}, acc -> Map.put(acc, :idempotent_hint, v)
        {:read_only, v}, acc -> Map.put(acc, :idempotent_hint, v)
        {:open_world, v}, acc -> Map.put(acc, :idempotent_hint, v)
        {k, v}, acc -> Map.put(acc, k, v)
      end)

    struct!(__MODULE__, attrs)
  end

  def to_json(%__MODULE__{} = annotation) do
    result =
      remove_nils(%{
        title: annotation.title,
        idempotentHint: annotation.idempotent_hint,
        destructiveHint: annotation.destructive_hint,
        readOnlyHint: annotation.read_only_hint,
        openWorldHint: annotation.open_world_hint
      })

    if map_size(result) == 0, do: nil, else: result
  end
end

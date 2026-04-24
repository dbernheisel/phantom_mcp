defmodule Phantom.UI do
  @moduledoc """
  Metadata for the MCP Apps extension (`io.modelcontextprotocol/ui`).

  MCP Apps allow servers to deliver interactive HTML user interfaces
  that render inside MCP hosts as sandboxed iframes. This module
  encapsulates the UI metadata for both tools (linking to a UI resource)
  and resources (CSP, permissions, sandbox configuration).

  See https://apps.extensions.modelcontextprotocol.io/
  """

  import Phantom.Utils

  @ui_keys ~w[resource_uri visibility connect_domains resource_domains frame_domains
              base_uri_domains permissions domain prefers_border]a

  @valid_visibility ~w[model app]a

  defstruct [
    :resource_uri,
    :connect_domains,
    :resource_domains,
    :frame_domains,
    :base_uri_domains,
    :permissions,
    :domain,
    :prefers_border,
    visibility: [:model, :app]
  ]

  @type visibility :: :model | :app

  @type t :: %__MODULE__{
          resource_uri: String.t() | nil,
          connect_domains: [String.t()] | nil,
          resource_domains: [String.t()] | nil,
          frame_domains: [String.t()] | nil,
          base_uri_domains: [String.t()] | nil,
          permissions: [atom()] | nil,
          domain: String.t() | nil,
          prefers_border: boolean() | nil,
          visibility: [visibility()]
        }

  @doc """
  Build a `%Phantom.UI{}` from a keyword list or map.

  Returns `nil` if no UI-related attributes are present.

  Raises `ArgumentError` if `visibility` contains unknown values.
  Valid visibility values are `:model` and `:app`.
  """
  @spec build(Keyword.t() | map()) :: t() | nil
  def build(attrs) when is_list(attrs), do: build(Map.new(attrs))

  def build(attrs) when is_map(attrs) do
    ui_attrs = Map.take(attrs, @ui_keys)

    if map_size(ui_attrs) == 0 do
      nil
    else
      ui_attrs
      |> validate_visibility()
      |> then(&struct!(__MODULE__, &1))
    end
  end

  defp validate_visibility(%{visibility: vis} = attrs) when is_list(vis) do
    normalized = Enum.map(vis, &to_visibility_atom/1)

    case normalized -- @valid_visibility do
      [] ->
        %{attrs | visibility: normalized}

      invalid ->
        raise ArgumentError,
              "invalid visibility values: #{inspect(invalid)}. " <>
                "Expected a list of #{inspect(@valid_visibility)}"
    end
  end

  defp validate_visibility(attrs), do: attrs

  defp to_visibility_atom(val) when val in @valid_visibility, do: val
  defp to_visibility_atom(val) when is_binary(val), do: String.to_existing_atom(val)
  defp to_visibility_atom(val), do: val

  @doc """
  Produce the `_meta` map for a tool's JSON representation.

  Returns `nil` when no UI is configured, which gets stripped by `remove_nils`.
  Visibility atoms are serialized to strings for the JSON wire format.
  """
  @spec to_tool_meta(t() | nil) :: %{ui: map()} | nil
  def to_tool_meta(nil), do: nil

  def to_tool_meta(%__MODULE__{} = ui) do
    %{
      ui:
        remove_nils(%{
          resourceUri: ui.resource_uri,
          visibility: Enum.map(ui.visibility, &to_string/1)
        })
    }
  end

  @doc """
  Produce the `_meta` map for a resource's JSON representation.

  Includes CSP domains, permissions, domain, and border preference.
  Returns `nil` when no resource-side metadata is present.
  """
  @spec to_resource_meta(t() | nil) :: %{ui: map()} | nil
  def to_resource_meta(nil), do: nil

  def to_resource_meta(%__MODULE__{} = ui) do
    csp =
      remove_nils(%{
        connectDomains: ui.connect_domains,
        resourceDomains: ui.resource_domains,
        frameDomains: ui.frame_domains,
        baseUriDomains: ui.base_uri_domains
      })

    permissions = build_permissions(ui.permissions)

    meta =
      remove_nils(%{
        csp: if(map_size(csp) > 0, do: csp),
        permissions: permissions,
        domain: ui.domain,
        prefersBorder: ui.prefers_border
      })

    if map_size(meta) == 0, do: nil, else: %{ui: meta}
  end

  @doc """
  Returns `true` if the tool should appear in `tools/list` (visible to the model).

  Tools without UI metadata are always visible. Tools with UI are visible
  when their visibility list includes `:model`.
  """
  @spec model_visible?(Phantom.Tool.t()) :: boolean()
  def model_visible?(%Phantom.Tool{ui: nil}), do: true
  def model_visible?(%Phantom.Tool{ui: %__MODULE__{visibility: vis}}), do: :model in vis

  defp build_permissions(nil), do: nil
  defp build_permissions([]), do: nil

  defp build_permissions(perms) when is_list(perms) do
    Map.new(perms, fn
      :clipboard_write -> {:clipboardWrite, %{}}
      perm -> {perm, %{}}
    end)
  end
end

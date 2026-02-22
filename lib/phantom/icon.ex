defmodule Phantom.Icon do
  @moduledoc """
  An optionally-sized icon that can be displayed in a user interface.

  Icons can be provided for the server implementation (via `use Phantom.Router`),
  as well as for individual tools, prompts, and resource templates.

  ## Fields

    - `:src` - (required) A standard URI pointing to an icon resource.
      May be an HTTP/HTTPS URL, a `data:` URI with Base64-encoded image data,
      or an MFA tuple `{module, function, args}` that is called at runtime.
    - `:mime_type` - Optional MIME type override if the source MIME type is missing or generic.
    - `:sizes` - Optional list of strings that specify sizes at which the icon can be used
      (e.g., `["48x48", "96x96"]`, or `["any"]` for SVGs).
    - `:theme` - Optional specifier for the theme this icon is designed for: `"dark"` or `"light"`.

  ## Example

      Phantom.Icon.build(%{
        src: "https://example.com/icon.png",
        mime_type: "image/png",
        sizes: ["48x48"],
        theme: "light"
      })

  """

  import Phantom.Utils

  @enforce_keys [:src]
  defstruct [
    :src,
    :mime_type,
    :sizes,
    :theme
  ]

  @type t :: %__MODULE__{
          src: String.t() | mfa(),
          mime_type: String.t() | nil,
          sizes: [String.t()] | nil,
          theme: String.t() | nil
        }

  @spec build(map() | Keyword.t()) :: t()
  def build(attrs) do
    struct!(__MODULE__, Map.new(attrs))
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = icon) do
    remove_nils(%{
      src: Phantom.Utils.resolve_url(icon.src),
      mimeType: icon.mime_type,
      sizes: icon.sizes,
      theme: icon.theme
    })
  end

  @spec to_json_list([t()] | nil) :: [map()] | nil
  def to_json_list(nil), do: nil
  def to_json_list([]), do: nil
  def to_json_list(icons) when is_list(icons), do: Enum.map(icons, &to_json/1)
end

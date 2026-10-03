defmodule Phantom.ResourceTemplate do
  @moduledoc """
  The Model Context Protocol (MCP) provides a standardized way for
  servers to expose resources to clients. Resources allow servers to
  share data that provides context to language models, such as files,
  database schemas, or application-specific information. Each resource
  is uniquely identified by a URI.

  https://modelcontextprotocol.io/specification/2025-03-26/server/resources
  """

  import Phantom.Utils

  @enforce_keys ~w[name handler function path router scheme uri uri_template]a
  defstruct [
    :name,
    :authority,
    :description,
    :function,
    :completion_function,
    :handler,
    :mime_type,
    :path,
    :router,
    :scheme,
    :size,
    :uri,
    :uri_template,
    :icons,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          authority: String.t(),
          description: String.t(),
          function: atom(),
          completion_function: atom(),
          handler: module(),
          mime_type: String.t(),
          path: String.t(),
          router: module(),
          scheme: String.t(),
          size: pos_integer(),
          meta: map(),
          uri: URI.t(),
          uri_template: String.t(),
          icons: [Phantom.Icon.t()] | nil
        }

  @type json :: %{
          required(:uri) => String.t(),
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:size) => pos_integer()
        }

  @spec build(map() | Keyword.t()) :: t()
  @doc """
  Build a resource_template spec

  The `Phantom.Router.resource/3` macro will build these specs.

  - `:name` - The name of the resource template.
  - `:uri` - The URI template of the resource in the style of `Plug.Router`, including the scheme.
    For example, you can define a path like `"myapp:///some/path/:project_id/:id` which
    will be parsed to include path params `%{"project_id" => _, "id" => _}`. The scheme can be
    `"https"`, `"git"`, `"file"`, or custom, eg `"myapp"`. A host is matched exactly
    (ignoring case), so `"myapp://settings"`, `"myapp://settings/:id"`, and
    `"https://example.com/:id"` only match URIs with that host.
  - `:description` - The description of the resource and when to use it.
  - `:handler` - The module to call.
  - `:function` - The function to call on the handler module.
  - `:completion_function` - The function to call on the handler module that will provide possible completion results.
  - `:mime_type` - the MIME type of the results.
  - `:router` - The Router module that will capture the URIs and route resources by URI to functions.
    This is constructed by the `Phantom.Router.resource/3` macro automatically as
    `MyApp.MyMCPRouter.ResourceRouter.{Scheme}`. The module does not need to exist at the time of
    building it-- it will be generated when added by `Phantom.Cache.add_resource_template/2`
    or by the `Phantom.Router.resource/3` macro.

  """
  def build(attrs) do
    uri =
      case attrs[:uri] do
        %URI{} = uri -> {:ok, uri}
        uri when is_binary(uri) -> URI.new(uri)
      end

    uri =
      case uri do
        {:ok, %URI{path: path, host: host, scheme: scheme} = uri}
        when is_binary(scheme) and (is_binary(path) or (is_binary(host) and host != "")) ->
          uri

        {:ok, uri} ->
          raise "Provided an invalid URI.\nResource URIs must contain a scheme and a host or path.\nProvided: #{URI.to_string(uri)}"

        {:error, invalid} ->
          raise "Provided an invalid URI.\nProvided: #{inspect(attrs[:uri])}\nError at: #{inspect(invalid)}"
      end

    icons =
      case attrs[:icons] do
        nil -> nil
        icons when is_list(icons) -> Enum.map(icons, &Phantom.Icon.build/1)
      end

    struct!(
      __MODULE__,
      attrs
      |> Map.new()
      |> Map.merge(%{
        name: attrs[:name] || to_string(attrs[:function]),
        authority: authority(uri),
        scheme: attrs[:scheme] || uri.scheme,
        path: attrs[:path] || uri.path || "",
        uri_template: "#{uri.scheme}://#{authority(uri)}#{to_uri_6570(uri.path || "")}",
        icons: icons
      })
    )
  end

  @spec to_json(t()) :: json()
  @doc """
  Represent a ResourceTemplate spec as json when listing the available resources to clients.
  """
  def to_json(%__MODULE__{} = resource) do
    base =
      remove_nils(%{
        uriTemplate: resource.uri_template,
        name: resource.name,
        size: resource.size,
        description: resource.description,
        mimeType: resource.mime_type,
        icons: Phantom.Icon.to_json_list(resource.icons)
      })

    case resource.meta do
      %{ui: %Phantom.UI{} = ui} ->
        case Phantom.UI.to_resource_meta(ui) do
          nil -> base
          meta -> Map.put(base, :_meta, meta)
        end

      _ ->
        base
    end
  end

  @doc false
  # The path a resource router matches for this template. The authority is
  # its first segment, so templates that differ only by host stay distinct.
  def route(%__MODULE__{authority: authority, path: path}),
    do: "/" <> authority_segment(authority) <> path

  @doc false
  # The `path_info` a resource router matches a requested URI with.
  def path_info(%URI{path: path} = uri) do
    segments =
      for segment <- :binary.split(path || "", "/", [:global]),
          segment != "",
          do: URI.decode(segment)

    [authority_segment(authority(uri)) | segments]
  end

  # Hosts are case-insensitive, and a port only matters when it is not the
  # scheme's default.
  defp authority(%URI{host: host, port: port, scheme: scheme}) do
    host = String.downcase(host || "")
    if port && port != URI.default_port(scheme), do: "#{host}:#{port}", else: host
  end

  # An encoded authority never contains "@", so it marks an empty one.
  defp authority_segment(""), do: "@"
  defp authority_segment(authority), do: URI.encode_www_form(authority)

  defp to_uri_6570(str) do
    # this is not a total 6570-compliant URI template.
    String.replace(str, ~r/:\w*/, fn ":" <> var -> "{#{var}}" end)
  end
end

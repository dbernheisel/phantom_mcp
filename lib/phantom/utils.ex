defmodule Phantom.Utils do
  @moduledoc false

  def remove_nils(map) do
    for {k, v} when not is_nil(v) <- map, into: %{}, do: {k, v}
  end

  @doc """
  Resolve a URL that may be a string or an MFA tuple.

  When given `{module, function, args}`, it calls `apply(module, function, args)`
  at runtime. This is useful for generating URLs from a Phoenix Endpoint or
  any other runtime URL builder.

  ## Examples

      resolve_url("https://example.com/icon.png")
      #=> "https://example.com/icon.png"

      resolve_url({MyAppWeb.Endpoint, :url, []})
      #=> "https://myapp.com"

      resolve_url({MyAppWeb.Helpers, :asset_url, ["/images/icon.png"]})
      #=> "https://myapp.com/images/icon.png"

  """
  def resolve_url({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args) do
    apply(mod, fun, args)
  end

  def resolve_url(url) when is_binary(url), do: url
  def resolve_url(nil), do: nil

  @doc false
  def get_var(attrs, field, keypath, env, default \\ nil) do
    case attrs[field] do
      nil ->
        if not Macro.Env.has_var?(env, {:session, nil}) do
          raise "#{inspect(field)} was not supplied to the response, and to fetch the default from the specification, Phantom requires the variable named `session` to exist."
        end

        case keypath do
          [:spec, source] ->
            quote generated: true do
              Map.get(var!(session).request.spec, unquote(source), unquote(default))
            end

          [:params | keypath] ->
            quote generated: true do
              get_in(var!(session).request.params, unquote(keypath)) || unquote(default)
            end
        end

      ast ->
        ast
    end
  end
end

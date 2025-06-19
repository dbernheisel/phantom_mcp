defmodule Phantom.Utils do
  @moduledoc false

  def remove_nils(map) do
    for {k, v} when not is_nil(v) <- map, into: %{}, do: {k, v}
  end

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

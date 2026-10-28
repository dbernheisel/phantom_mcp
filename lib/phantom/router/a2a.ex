defmodule Phantom.Router.A2A do
  @moduledoc false
  # Builds and matches the `agent` routes of a router.

  @segment ~r/\A(:[a-z_][A-Za-z0-9_]*|[A-Za-z0-9._~-]+)\z/

  def route(path, handler, resolver) when is_atom(resolver),
    do: build(path, handler, [], resolver)

  def route(path, handler, opts) when is_list(opts), do: build(path, handler, opts, nil)

  defp build(path, handler, opts, resolver) when is_binary(path) and is_atom(handler) do
    segments = String.split(path, "/")

    if not Enum.all?(segments, &Regex.match?(@segment, &1)) or
         List.last(segments) == "agent-card.json" do
      raise ArgumentError,
            "invalid agent path #{inspect(path)}: segments are letters, digits, - . _ ~, " <>
              "or path params"
    end

    params? = Enum.any?(segments, &String.starts_with?(&1, ":"))

    if params? and is_nil(resolver) do
      raise ArgumentError,
            "agent #{inspect(path)} has path params, so it needs a resolver: " <>
              "agent #{inspect(path)}, #{inspect(handler)}, :resolve"
    end

    %{
      id: path,
      segments: segments,
      handler: handler,
      opts: opts,
      resolver: resolver,
      params?: params?
    }
  end

  @doc "The route for a request path, static routes first, with its path params"
  def match(router, segments) do
    {static, dynamic} = Enum.split_with(router.__phantom__(:info).agents, &(not &1.params?))

    Enum.find_value(static ++ dynamic, :error, fn route ->
      case match_segments(route.segments, segments, %{}) do
        {:ok, params} -> {:ok, route, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | pattern], [segment | segments], params),
    do: match_segments(pattern, segments, Map.put(params, name, segment))

  defp match_segments([segment | pattern], [segment | segments], params),
    do: match_segments(pattern, segments, params)

  defp match_segments(_pattern, _segments, _params), do: :error
end

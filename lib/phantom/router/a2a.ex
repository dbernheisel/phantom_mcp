defmodule Phantom.Router.A2A do
  @moduledoc false
  # Builds and matches the `agent` routes of a router.

  @segment ~r/\A(:[a-z_][A-Za-z0-9_]*|[A-Za-z0-9._~-]+)\z/

  # Segments the HTTP+JSON binding routes on.
  @reserved ~w[tasks extendedAgentCard pushNotificationConfigs]

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

    if reserved = Enum.find(segments, &(&1 in @reserved)) do
      raise ArgumentError,
            "invalid agent path #{inspect(path)}: #{inspect(reserved)} is reserved for the " <>
              "HTTP+JSON binding"
    end

    {params, _match} = Plug.Router.Utils.build_path_match(path)
    params? = params != []

    if params? and is_nil(resolver) do
      raise ArgumentError,
            "agent #{inspect(path)} has path params, so it needs a resolver: " <>
              "agent #{inspect(path)}, #{inspect(handler)}, :resolve"
    end

    %{
      id: path,
      handler: handler,
      opts: opts,
      resolver: resolver,
      params?: params?
    }
  end

  @doc "The default `c:Phantom.Router.list_agents/2`"
  def default_list(router, session) do
    paths =
      for %{params?: false, id: id} <- router.__phantom__(:info).agents,
          is_nil(session.allowed_agents) or id in session.allowed_agents,
          do: id

    {:ok, paths, nil}
  end

  @doc false
  # The router's `__phantom_agent__/2`: a function head per route, matched with
  # `Plug.Router`'s path syntax, so a request path finds its route by pattern match.
  def compile(routes) do
    clauses =
      for route <- routes do
        {params, match} = Plug.Router.Utils.build_path_match(route.id)
        path_params = for name <- params, do: {Atom.to_string(name), Macro.var(name, nil)}

        quote generated: true do
          def __phantom_agent__(unquote(match), unquote(route.params?)),
            do: {:ok, unquote(Macro.escape(route)), %{unquote_splicing(path_params)}}
        end
      end

    quote generated: true do
      @doc false
      unquote(clauses)
      def __phantom_agent__(_segments, _params?), do: :error
    end
  end

  @doc "The route for a request path, static routes first, with its path params"
  def match(router, segments) do
    with :error <- router.__phantom_agent__(segments, false),
         do: router.__phantom_agent__(segments, true)
  end

  @doc "The static (`false`) or dynamic (`true`) route for a request path"
  def match(router, segments, params?), do: router.__phantom_agent__(segments, params?)
end

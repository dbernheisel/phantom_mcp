defmodule Phantom.Router.Skills do
  @moduledoc false
  # Serves the MCP Skills extension from a router's skill routes, which are
  # resource templates under `skill://<path>/*file`.

  require Logger

  alias Phantom.Cache
  alias Phantom.Request
  alias Phantom.ResourceTemplate
  alias Phantom.Session
  alias Phantom.Skill

  ## Routes

  # A route's path segments, without its `*file` glob.
  def segments(%ResourceTemplate{authority: authority, path: path}) do
    [authority | path |> String.replace_suffix("/*file", "") |> String.split("/", trim: true)]
  end

  # Deepest first; at the same depth, static segments before path params. The
  # generated resource router matches in this order.
  def route_order(route), do: {-length(segments(route)), Enum.map(segments(route), &param?/1)}

  defp param?(":" <> _), do: true
  defp param?(_segment), do: false

  defp skill_routes(routes) do
    routes |> Enum.filter(&(&1.scheme == "skill")) |> Enum.sort_by(&route_order/1)
  end

  # A route nested under another must not have path params below it, since its
  # files are part of the other skill's manifest.
  def validate_nesting!(routes) do
    for outer <- routes, inner <- routes, outer != inner do
      {prefix, rest} = Enum.split(segments(inner), length(segments(outer)))

      if length(rest) > 0 and compatible?(segments(outer), prefix) and Enum.any?(rest, &param?/1) do
        raise ArgumentError,
              "skill #{inspect(inner.name)} is nested in skill #{inspect(outer.name)}, " <>
                "so it can't have path params below #{inspect(outer.name)}"
      end
    end

    :ok
  end

  defp compatible?(a, b) do
    length(a) == length(b) and
      Enum.all?(Enum.zip(a, b), fn {x, y} -> x == y or param?(x) or param?(y) end)
  end

  defp match(route_segments, segments, params \\ %{})
  defp match([], [], params), do: {:ok, params}

  defp match([":" <> param | route_segments], [value | segments], params),
    do: match(route_segments, segments, Map.put(params, param, value))

  defp match([same | route_segments], [same | segments], params),
    do: match(route_segments, segments, params)

  defp match(_route_segments, _segments, _params), do: :error

  defp concrete(route, params) do
    Enum.map(segments(route), fn
      ":" <> param -> params[param]
      segment -> segment
    end)
  end

  defp base_uri(segments), do: "skill://" <> Enum.map_join(segments, "/", &Skill.encode_segment/1)

  # The routes serving `segments`, deepest first: its own route, then the route of
  # each skill it's nested in.
  defp chain(routes, segments) do
    for depth <- length(segments)..1//-1,
        prefix = Enum.take(segments, depth),
        route = Enum.find(routes, &match?({:ok, _}, match(segments(&1), prefix))),
        route != nil,
        do: {route, prefix}
  end

  # Routed skills nested directly in the skill at `segments`.
  defp nested(routes, segments) do
    depth = length(segments)

    candidates =
      routes
      |> Enum.flat_map(fn route ->
        {prefix, rest} = Enum.split(segments(route), depth)

        if rest != [] and match?({:ok, _}, match(prefix, segments)),
          do: [{route, segments ++ rest}],
          else: []
      end)
      |> Enum.uniq_by(&elem(&1, 1))

    Enum.reject(candidates, fn {_, inner} ->
      Enum.any?(candidates, fn {_, outer} ->
        length(outer) < length(inner) and Enum.take(inner, length(outer)) == outer
      end)
    end)
  end

  ## Actions

  # Returns `{:ok, skill, session}`, `{:absent, session}` or `{:error, error, session}`.
  defp call(route, segments, session) do
    {:ok, params} = match(segments(route), segments)
    route |> apply_action(params, session) |> action_result(route)
  end

  defp apply_action(route, params, session) do
    apply(route.handler, route.function, [params, session])
  rescue
    error in FunctionClauseError ->
      if {error.module, error.function, error.arity} == {route.handler, route.function, 2},
        do: {:reply, nil, session},
        else: reraise(error, __STACKTRACE__)
  end

  defp action_result({:reply, %Skill{frontmatter: %{"name" => name}} = skill, session}, route) do
    if name == List.last(segments(route)) do
      {:ok, skill, session}
    else
      Logger.error(
        "#{inspect(route.handler)}.#{route.function}/2 returned the skill #{inspect(name)} " <>
          "for #{inspect(route.name)}; a skill's name must be the last segment of its path"
      )

      {:error, Request.internal_error(), session}
    end
  end

  defp action_result({:reply, nil, session}, _route), do: {:absent, session}
  defp action_result({:error, _error, %Session{}} = error, _route), do: error

  defp action_result(other, route) do
    raise ArgumentError,
          "#{inspect(route.handler)}.#{route.function}/2 must return " <>
            "{:reply, %Phantom.Skill{} | nil, session} or {:error, error, session}; " <>
            "skill actions are synchronous. Got: #{inspect(other)}"
  end

  # The skill's files, with each nested skill's files in place of the skill's own
  # copy of its directory. Returns the files, as in `Skill.manifest/2`, and every
  # skill they come from.
  defp tree(routes, skill, segments, session) do
    own = Map.new(skill.files, fn {path, _content} -> {path, {skill, path}} end)

    Enum.reduce(nested(routes, segments), {own, [skill]}, fn {route, inner}, {files, skills} ->
      case call(route, inner, session) do
        {:ok, nested_skill, _session} ->
          {nested_files, nested_skills} = tree(routes, nested_skill, inner, session)
          dir = inner |> Enum.drop(length(segments)) |> Enum.join("/")

          files =
            files
            |> Map.reject(fn {path, _} -> String.starts_with?(path, dir <> "/") end)
            |> Map.merge(
              Map.new(nested_files, fn {path, served} -> {dir <> "/" <> path, served} end)
            )

          {files, skills ++ nested_skills}

        _absent_or_error ->
          {files, skills}
      end
    end)
  end

  defp entry(router, skill, segments, session) do
    {files, skills} =
      tree(skill_routes(Cache.list(nil, router, :resource_templates)), skill, segments, session)

    base_uri = base_uri(segments)

    resources =
      if Enum.any?(skills, & &1.dynamic),
        do: {:ok, "dynamic"},
        else: Skill.manifest(files, base_uri)

    case resources do
      {:ok, resources} ->
        {:ok,
         %{uri: base_uri <> "/SKILL.md", frontmatter: skill.frontmatter, resources: resources},
         skills}

      {:error, message} ->
        Logger.error("Skill #{base_uri} can't be served: #{message}")
        {:error, Request.internal_error(), session}
    end
  end

  ## Methods

  def list(router, session, cursor) do
    routes =
      session
      |> Cache.list(router, :resource_templates)
      |> Enum.filter(
        &(&1.scheme == "skill" and not Enum.any?(segments(&1), fn s -> param?(s) end))
      )

    case Phantom.Router.paginate(routes, cursor, & &1) do
      {:ok, page, next_cursor} ->
        results = Enum.map(page, &list_entry(router, &1, session))
        listed = for {:ok, entry, skills} <- results, do: {entry, skills}

        # A route that serves no skill to this session makes the listing specific to it.
        hints =
          if length(listed) == length(page),
            do: Skill.cache_hints(Enum.flat_map(listed, &elem(&1, 1)), session),
            else: [ttl_ms: 0, scope: :private]

        {:reply,
         %{skills: Enum.map(listed, &elem(&1, 0))}
         |> Map.merge(next_cursor || %{})
         |> Request.with_cache(hints), session}

      {:error, error} ->
        {:error, error, session}
    end
  end

  # A skill that fails is left out, and the rest are listed.
  defp list_entry(router, route, session) do
    segments = segments(route)

    with {:ok, skill, session} <- call(route, segments, session) do
      entry(router, skill, segments, session)
    end
  catch
    kind, reason ->
      Logger.error(
        "Skill #{inspect(route.name)} was left out of skills/list: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      :error
  end

  def get(router, session, uri) do
    with {:ok, route, segments, "SKILL.md"} <- resolve(router, session, uri),
         true <- route in Cache.list(session, router, :resource_templates),
         {:ok, skill, session} <- call(route, segments, session),
         {:ok, entry, skills} <- entry(router, skill, segments, session) do
      {:reply, Request.with_cache(%{skill: entry}, Skill.cache_hints(skills, session)), session}
    else
      {:error, _error, %Session{}} = error -> error
      _ -> {:error, invalid_params("No skill is served at #{uri}"), session}
    end
  end

  def read_directory(router, session, uri) do
    with {:ok, _route, segments, dir} <- resolve(router, session, uri),
         {:ok, skill, skill_segments, session} <- serving(router, segments, session),
         routes = skill_routes(Cache.list(nil, router, :resource_templates)),
         {files, _skills} = tree(routes, skill, skill_segments, session),
         dir = relative(segments, dir, skill_segments),
         {:ok, resources} <- Skill.list_directory(files, base_uri(skill_segments), dir) do
      # Directories are listed whole, so a cursor is never needed.
      {:reply, %{resources: resources}, session}
    else
      {:error, _error, %Session{}} = error -> error
      _ -> {:error, invalid_params("#{uri} is not a directory resource"), session}
    end
  end

  # Called by `Phantom.ResourcePlug` for `resources/read` of a skill route's file.
  def read(route, %{"file" => file} = params, uri, session) do
    segments = concrete(route, Map.delete(params, "file"))

    with true <- Skill.uri(base_uri(segments), Enum.join(file, "/")) == uri,
         {:ok, skill, skill_segments, session} <-
           serving(session.router, segments, session),
         {:ok, content} <-
           Skill.read(skill, relative(segments, Enum.join(file, "/"), skill_segments), uri) do
      {:reply, content, session}
    else
      {:error, _error, %Session{}} = error -> error
      _ -> {:reply, nil, session}
    end
  end

  # Resolves a canonical skill URI through the router's resource router to its
  # route, the route's segments, and the path within the skill.
  defp resolve(router, session, uri) do
    with {:ok, {^uri, %{"file" => file} = params, %ResourceTemplate{scheme: "skill"} = route}} <-
           Phantom.Router.resolve_resource(router, session, uri),
         segments = concrete(route, Map.delete(params, "file")),
         path = Enum.join(file, "/"),
         true <- Skill.uri(base_uri(segments), path) == uri do
      {:ok, route, segments, path}
    else
      _ -> :error
    end
  end

  # The skill that serves a path under `segments`: the route's own skill, or when it
  # serves none, the skill it's nested in. Each must be allowed for the session, or
  # be nested in a skill that is.
  defp serving(router, segments, session) do
    allowed = Cache.list(session, router, :resource_templates)
    chain = chain(skill_routes(Cache.list(nil, router, :resource_templates)), segments)
    serve(chain, allowed, session, nil)
  end

  defp serve([], _allowed, session, nil), do: {:absent, session}
  defp serve([], _allowed, _session, error), do: error

  defp serve([{route, segments} | outer] = chain, allowed, session, error) do
    if Enum.any?(chain, &(elem(&1, 0) in allowed)),
      do: route |> call(segments, session) |> served(segments, outer, allowed, error),
      else: {:absent, session}
  end

  defp served({:ok, skill, session}, segments, _outer, _allowed, _error),
    do: {:ok, skill, segments, session}

  defp served({:absent, session}, _segments, outer, allowed, error),
    do: serve(outer, allowed, session, error)

  defp served({:error, _error, session} = new_error, _segments, outer, allowed, error),
    do: serve(outer, allowed, session, error || new_error)

  # A path under `segments`, made relative to the skill at `skill_segments`.
  defp relative(segments, path, skill_segments) do
    segments
    |> Enum.drop(length(skill_segments))
    |> Enum.concat(String.split(path, "/", trim: true))
    |> Enum.join("/")
  end

  defp invalid_params(message), do: %{Request.invalid_params() | message: message}
end

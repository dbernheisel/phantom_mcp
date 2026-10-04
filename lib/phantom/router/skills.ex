defmodule Phantom.Router.Skills do
  @moduledoc false
  # Serves the MCP Skills extension from a router's skill routes, which are
  # resource templates under `skill://<path>/*file`. The router's generated
  # resource router resolves every skill URI, so a file always belongs to the
  # deepest skill route whose path contains it.

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

  # A route nested under another must not have path params below it, since its
  # files are part of the other skill's manifest.
  def validate_nesting!(routes) do
    for outer <- routes, inner <- routes, outer != inner do
      {prefix, rest} = Enum.split(segments(inner), length(segments(outer)))

      if rest != [] and compatible?(segments(outer), prefix) and Enum.any?(rest, &param?/1) do
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

  defp skill_routes(router) do
    Enum.filter(Cache.list(nil, router, :resource_templates), &(&1.scheme == "skill"))
  end

  defp concrete(route, params) do
    Enum.map(segments(route), fn
      ":" <> param -> params[param]
      segment -> segment
    end)
  end

  defp base_uri(segments), do: "skill://" <> Enum.map_join(segments, "/", &Skill.encode_segment/1)

  # Resolves a canonical skill URI through the resource router to the route that
  # serves it, the route's params and segments, and the path within the skill.
  defp resolve(router, uri) do
    with {:ok, {^uri, %{"file" => file} = params, %ResourceTemplate{scheme: "skill"} = route}} <-
           Phantom.Router.resolve_resource(router, nil, uri),
         params = Map.delete(params, "file"),
         segments = concrete(route, params),
         path = Enum.join(file, "/"),
         true <- Skill.uri(base_uri(segments), path) == uri do
      {:ok, route, params, segments, path}
    else
      _ -> :error
    end
  end

  # The skill route whose root is exactly `segments`, as the resource router resolves it.
  defp root(router, segments) do
    case resolve(router, base_uri(segments)) do
      {:ok, route, params, ^segments, ""} -> {:ok, route, params}
      _ -> :error
    end
  end

  # Skill routes nested in the skill at `segments`, at any depth.
  defp descendants(router, segments) do
    depth = length(segments)

    for route <- skill_routes(router),
        {_prefix, rest} = Enum.split(segments(route), depth),
        rest != [] and not Enum.any?(rest, &param?/1),
        inner = segments ++ rest,
        {:ok, ^route, params} <- [root(router, inner)],
        do: {route, params, inner}
  end

  # A route is accessible when it, or a skill route it's nested in, is allowed.
  defp accessible?(router, session, route, segments) do
    allowed = Cache.list(session, router, :resource_templates)
    route in allowed or Enum.any?(ancestors(router, segments), &(&1 in allowed))
  end

  defp ancestors(router, segments) do
    for depth <- (length(segments) - 1)..1//-1,
        {:ok, route, _params} <- [root(router, Enum.take(segments, depth))],
        do: route
  end

  ## Actions

  # Returns `{:ok, skill, session}`, `{:absent, session}` or `{:error, error, session}`.
  defp call(route, params, session) do
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

  # The files of the skill at `segments`, each from the skill that owns it: the
  # deepest of the skill and its nested skills whose directory contains the file.
  # Returns the files, as in `Skill.manifest/2`, and every skill they come from.
  defp tree(router, skill, segments, session) do
    owners =
      for {route, params, inner} <- descendants(router, segments),
          do: {inner |> Enum.drop(length(segments)) |> Enum.join("/"), route, params}

    dirs = Enum.map(owners, &elem(&1, 0))

    skills =
      [{"", skill}] ++
        for {dir, route, params} <- owners,
            {:ok, nested, _session} <- [call(route, params, session)],
            do: {dir, nested}

    files =
      for {dir, owner} <- skills,
          {path, _content} <- owner.files,
          full = if(dir == "", do: path, else: dir <> "/" <> path),
          owner_dir(full, dirs) == dir,
          into: %{},
          do: {full, {owner, path}}

    {files, Enum.map(skills, &elem(&1, 1))}
  end

  defp owner_dir(path, dirs) do
    dirs
    |> Enum.filter(&String.starts_with?(path, &1 <> "/"))
    |> Enum.max_by(&String.length/1, fn -> "" end)
  end

  defp entry(router, skill, segments, session) do
    {files, skills} = tree(router, skill, segments, session)
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

    with {:ok, skill, session} <- call(route, %{}, session) do
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
    with {:ok, route, params, segments, "SKILL.md"} <- resolve(router, uri),
         true <- accessible?(router, session, route, segments),
         {:ok, skill, session} <- call(route, params, session),
         {:ok, entry, skills} <- entry(router, skill, segments, session) do
      {:reply, Request.with_cache(%{skill: entry}, Skill.cache_hints(skills, session)), session}
    else
      {:error, _error, %Session{}} = error -> error
      _ -> {:error, invalid_params("No skill is served at #{uri}"), session}
    end
  end

  def read_directory(router, session, uri) do
    with {:ok, route, params, segments, dir} <- resolve(router, uri),
         true <- accessible?(router, session, route, segments),
         {:ok, skill, session} <- call(route, params, session),
         {files, _skills} = tree(router, skill, segments, session),
         {:ok, resources} <- Skill.list_directory(files, base_uri(segments), dir) do
      # Directories are listed whole, so a cursor is never needed.
      {:reply, %{resources: resources}, session}
    else
      {:error, _error, %Session{}} = error -> error
      _ -> {:error, invalid_params("#{uri} is not a directory resource"), session}
    end
  end

  # Called by `Phantom.ResourcePlug` for `resources/read` of a skill route's file.
  def read(route, %{"file" => file} = params, uri, session) do
    params = Map.delete(params, "file")
    segments = concrete(route, params)
    path = Enum.join(file, "/")

    with true <- Skill.uri(base_uri(segments), path) == uri,
         true <- accessible?(session.router, session, route, segments),
         {:ok, skill, session} <- call(route, params, session),
         {:ok, content} <- Skill.read(skill, path, uri) do
      {:reply, content, session}
    else
      {:error, _error, %Session{}} = error -> error
      _ -> {:reply, nil, session}
    end
  end

  defp invalid_params(message), do: %{Request.invalid_params() | message: message}
end

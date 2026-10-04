defmodule Phantom.Router.Skills do
  @moduledoc false
  # This module serves the MCP Skills extension from the skill routes of a router.

  require Logger

  alias Phantom.Cache
  alias Phantom.Request
  alias Phantom.ResourceTemplate
  alias Phantom.Session
  alias Phantom.Skill

  def segments(%ResourceTemplate{authority: authority, path: path}) do
    [authority | path |> String.replace_suffix("/*file", "") |> String.split("/", trim: true)]
  end

  def route_order(route), do: {-length(segments(route)), Enum.map(segments(route), &param?/1)}

  defp param?(":" <> _), do: true
  defp param?(_segment), do: false

  # A nested route cannot have path params, because its files are in the manifest of its parent.
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

  defp listable?(route) do
    route.scheme == "skill" and not Enum.any?(segments(route), &param?/1)
  end

  defp concrete(route, params) do
    Enum.map(segments(route), fn
      ":" <> param -> params[param]
      segment -> segment
    end)
  end

  defp base_uri(segments), do: "skill://" <> Enum.map_join(segments, "/", &encode_segment/1)

  defp uri(base_uri, ""), do: base_uri

  defp uri(base_uri, path) do
    base_uri <> "/" <> Enum.map_join(String.split(path, "/"), "/", &encode_segment/1)
  end

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp resolve(router, uri) do
    case Phantom.Router.resolve_resource(router, nil, uri) do
      {:ok, {^uri, params, %ResourceTemplate{scheme: "skill"} = route}} ->
        locate(route, params, uri)

      _ ->
        :error
    end
  end

  defp locate(route, %{"file" => file} = params, uri) do
    params = Map.delete(params, "file")
    segments = concrete(route, params)
    path = Enum.join(file, "/")

    if uri(base_uri(segments), path) == uri,
      do: {:ok, route, params, segments, path},
      else: :error
  end

  defp root(router, segments) do
    case resolve(router, base_uri(segments)) do
      {:ok, route, params, ^segments, ""} -> {:ok, route, params}
      _ -> :error
    end
  end

  defp descendants(router, routes, segments) do
    depth = length(segments)

    for route <- routes,
        {_prefix, rest} = Enum.split(segments(route), depth),
        rest != [] and not Enum.any?(rest, &param?/1),
        inner = segments ++ rest,
        {:ok, ^route, params} <- [root(router, inner)],
        do: {route, params, inner}
  end

  defp accessible?(router, session, route, segments) do
    allowed = Cache.list(session, router, :resource_templates)
    route in allowed or Enum.any?(ancestors(router, segments), &(&1 in allowed))
  end

  defp ancestors(router, segments) do
    for depth <- (length(segments) - 1)..1//-1,
        {:ok, route, _params} <- [root(router, Enum.take(segments, depth))],
        do: route
  end

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

  defp tree(router, routes, skill, segments, session) do
    nested =
      for {route, params, inner} <- descendants(router, routes, segments),
          do: {inner |> Enum.drop(length(segments)) |> Enum.join("/"), route, params}

    nested_dirs = Enum.map(nested, &elem(&1, 0))

    nested_skills =
      for {dir, route, params} <- nested,
          {:ok, nested_skill, _session} <- [call(route, params, session)],
          do: {dir, nested_skill}

    skills = [{"", skill} | nested_skills]

    files =
      for {dir, owner} <- skills,
          {path, _content} <- owner.files,
          full_path = if(dir == "", do: path, else: dir <> "/" <> path),
          owner_dir(full_path, nested_dirs) == dir,
          into: %{},
          do: {full_path, {owner, path}}

    {files, Enum.map(skills, &elem(&1, 1))}
  end

  defp owner_dir(path, dirs) do
    dirs
    |> Enum.filter(&String.starts_with?(path, &1 <> "/"))
    |> Enum.max_by(&String.length/1, fn -> "" end)
  end

  defp entry(router, routes, skill, segments, session) do
    {files, skills} = tree(router, routes, skill, segments, session)
    base_uri = base_uri(segments)

    resources =
      if Enum.any?(skills, & &1.dynamic),
        do: {:ok, "dynamic"},
        else: manifest(files, base_uri)

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

  defp manifest(files, base_uri) do
    resources =
      for {path, {skill, own_path}} <- Enum.sort(files) do
        bytes = Skill.render(skill, own_path)
        %{uri: uri(base_uri, path), digest: digest(bytes), size: byte_size(bytes)}
      end

    total_size = resources |> Enum.map(& &1.size) |> Enum.sum()

    case Skill.check_limits(length(resources), total_size) do
      :ok -> {:ok, resources}
      {:error, reason} -> {:error, "#{base_uri} has #{reason}"}
    end
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp cache_hints(skills, session) do
    hints = Enum.map(skills, & &1.cache)

    if hints == [] or nil in hints do
      [ttl_ms: 0, scope: :private]
    else
      public? =
        is_nil(session.allowed_resource_templates) and
          Enum.all?(hints, &(&1[:scope] == :public))

      [
        ttl_ms: hints |> Enum.map(& &1[:ttl_ms]) |> Enum.min(),
        scope: if(public?, do: :public, else: :private)
      ]
    end
  end

  def list(router, session, cursor) do
    routes = session |> Cache.list(router, :resource_templates) |> Enum.filter(&listable?/1)

    case Phantom.Router.paginate(routes, cursor, & &1) do
      {:ok, page, next_cursor} ->
        all_routes = skill_routes(router)
        results = Enum.map(page, &list_entry(router, all_routes, &1, session))
        listed = for {:ok, entry, skills} <- results, do: {entry, skills}

        # The listing is private when a route serves no skill to this session.
        hints =
          if length(listed) == length(page),
            do: cache_hints(Enum.flat_map(listed, &elem(&1, 1)), session),
            else: [ttl_ms: 0, scope: :private]

        {:reply,
         %{skills: Enum.map(listed, &elem(&1, 0))}
         |> Map.merge(next_cursor || %{})
         |> Request.with_cache(hints), session}

      {:error, error} ->
        {:error, error, session}
    end
  end

  defp list_entry(router, routes, route, session) do
    with {:ok, skill, session} <- call(route, %{}, session) do
      entry(router, routes, skill, segments(route), session)
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
         {:ok, entry, skills} <- entry(router, skill_routes(router), skill, segments, session) do
      {:reply, Request.with_cache(%{skill: entry}, cache_hints(skills, session)), session}
    else
      {:error, _error, %Session{}} = error -> error
      _ -> {:error, invalid_params("No skill is served at #{uri}"), session}
    end
  end

  def read_directory(router, session, uri) do
    with {:ok, route, params, segments, dir} <- resolve(router, uri),
         true <- accessible?(router, session, route, segments),
         {:ok, skill, session} <- call(route, params, session),
         {files, _skills} = tree(router, skill_routes(router), skill, segments, session),
         {:ok, resources} <- list_directory(files, base_uri(segments), dir) do
      {:reply, %{resources: resources}, session}
    else
      {:error, _error, %Session{}} = error -> error
      _ -> {:error, invalid_params("#{uri} is not a directory resource"), session}
    end
  end

  def read(route, params, uri, session) do
    with {:ok, route, params, segments, path} <- locate(route, params, uri),
         true <- accessible?(session.router, session, route, segments),
         {:ok, skill, session} <- call(route, params, session),
         {:ok, content} <- file_content(skill, path, uri) do
      {:reply, content, session}
    else
      {:error, _error, %Session{}} = error -> error
      _ -> {:reply, nil, session}
    end
  end

  defp file_content(%Skill{files: files} = skill, path, uri) when is_map_key(files, path) do
    bytes = Skill.render(skill, path)
    content = %{uri: uri, mimeType: MIME.from_path(path)}

    if String.valid?(bytes),
      do: {:ok, Map.put(content, :text, bytes)},
      else: {:ok, Map.put(content, :blob, Base.encode64(bytes))}
  end

  defp file_content(%Skill{}, _path, _uri), do: :error

  defp list_directory(files, base_uri, dir) do
    prefix = if dir == "", do: "", else: dir <> "/"

    children =
      for {path, served} <- files, String.starts_with?(path, prefix), uniq: true do
        case path |> String.replace_prefix(prefix, "") |> String.split("/", parts: 2) do
          [file] -> {file, child(file, served)}
          [subdir, _] -> {subdir, %{name: subdir, mimeType: "inode/directory"}}
        end
      end

    if children == [] do
      :error
    else
      dir_uri = uri(base_uri, dir)

      {:ok,
       children
       |> Enum.sort_by(&elem(&1, 0))
       |> Enum.map(fn {name, child} ->
         Map.put(child, :uri, dir_uri <> "/" <> encode_segment(name))
       end)}
    end
  end

  defp child("SKILL.md", {%Skill{frontmatter: frontmatter}, "SKILL.md"}) do
    %{
      name: frontmatter["name"],
      description: frontmatter["description"],
      mimeType: "text/markdown"
    }
  end

  defp child(file, _served), do: %{name: file, mimeType: MIME.from_path(file)}

  defp invalid_params(message), do: %{Request.invalid_params() | message: message}
end

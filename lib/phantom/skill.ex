defmodule Phantom.Skill do
  @moduledoc """
  A skill served with the MCP Skills extension (`io.modelcontextprotocol/skills`).

  A skill is a directory of files with a `SKILL.md` at its root, as defined by the
  [Agent Skills specification](https://agentskills.io/specification). Route a skill
  path to an action in your `Phantom.Router`, and return a `%Phantom.Skill{}` from it,
  much like a Phoenix controller renders a template:

      defmodule MyApp.MCP.Router do
        use Phantom.Router, name: "MyApp", vsn: "1.0"

        # skill://git-workflow/SKILL.md → MyApp.MCP.Skills.git_workflow/2
        skill "git-workflow", MyApp.MCP.Skills

        skill "acme/billing/refunds", MyApp.MCP.Skills, :refunds
        skill "studies/:study_id/study-review", MyApp.MCP.Skills, :study_review
      end

  The final segment of the path is the skill's name, and must equal the `name` in its
  frontmatter. Earlier segments organize skills and may contain path params, except the
  first. Skills with path params are left out of `skills/list`, but clients can still
  get them by URI.

  Each skill is a resource template named by its path, so skill paths share names with
  resource templates, and `Phantom.Session.allow_resource_templates/2` limits skills too.
  Skill routes are not listed in `resources/templates/list`.

  ## Actions

  An action receives the path params and the session, and returns
  `{:reply, %Phantom.Skill{}, session}`. Return `{:reply, nil, session}` when no skill
  is served at that path. Actions are synchronous.

  Phantom calls the same action for `skills/list`, `skills/get`, `resources/read`, and
  `resources/directory/read`, and serves the part each method asks for. Digests are
  computed from what the action returns, so the action must return the same files for
  the same session. If it cannot, mark the skill with `dynamic/1`.

  ## Nested skills

  A skill routed under another skill's path is nested in it. Each file belongs to the
  deepest skill whose directory contains it: the parent's manifest and directory
  listings take each nested skill's files from its own action, and leave out the
  parent's own files in that directory. A nested action that returns `nil` or an error
  serves no files; one that raises fails the parent's `skills/get` and is left out of
  `skills/list`. A session allowed a skill may use every skill nested in it.

  ## Rendering

  A file's contents are either a binary or a function that returns iodata. A function
  is only called when Phantom needs that file: `resources/read` renders the one file
  read, while `skills/list` and `skills/get` render every file for their digests.

  ## Caching

  `skills/list` and `skills/get` results are private and uncached unless the action
  calls `with_cache/2`. Only declare `scope: :public` when the skill is the same for
  every user who can see it.

      {:reply, git_workflow(%{}) |> Phantom.Skill.with_cache(ttl_ms: 300_000, scope: :public),
       session}

  ## Embedding skills from files

  `embed_skills/1` compiles skill directories into functions, the way
  `Phoenix.Component.embed_templates/1` compiles templates. Files ending in `.eex` are
  rendered with assigns; the frontmatter of `SKILL.md` is parsed at compile time and
  must not contain EEx.

      defmodule MyApp.MCP.Skills do
        use Phantom.Skill

        # skills/refunds/SKILL.md.eex, skills/refunds/examples/email.md
        # → refunds(assigns)
        embed_skills "skills/*"

        def refunds(_params, session) do
          {:reply, refunds(%{user: session.assigns.user}), session}
        end

        def git_workflow(_params, session) do
          {:reply,
           Phantom.Skill.new(
             %{name: "git-workflow", description: "Follow this team's Git conventions"},
             %{"SKILL.md" => "# Git workflow\\n\\nBranch from `main`.\\n"}
           ), session}
        end
      end

  Parsing frontmatter requires the optional `:yamerl` dependency:

      {:yamerl, "~> 0.10"}
  """

  @compile {:no_warn_undefined, :yamerl_constr}

  @max_files 512
  @max_size 16_777_216
  @name_pattern ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @frontmatter_pattern ~r/\A---[ \t]*\R(?<yaml>.*?)^---[ \t]*(?:\R|\z)(?<body>.*)\z/ms
  @simple_key ~r/\A[A-Za-z0-9_-]+\z/

  defstruct frontmatter: %{}, files: %{}, dynamic: false, cache: nil

  @type t :: %__MODULE__{
          frontmatter: %{required(String.t()) => term()},
          files: %{required(String.t()) => binary() | (-> iodata())},
          dynamic: boolean(),
          cache: nil | [ttl_ms: non_neg_integer(), scope: :public | :private]
        }

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Phantom.Skill, only: [embed_skills: 1]
      Module.register_attribute(__MODULE__, :phantom_skill_hashes, accumulate: true)
      @before_compile Phantom.Skill
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    hashes = Module.get_attribute(env.module, :phantom_skill_hashes)

    quote do
      @doc false
      def __mix_recompile__? do
        Enum.any?(unquote(hashes), fn {pattern, hash} ->
          Phantom.Skill.__files_hash__(pattern) != hash
        end)
      end
    end
  end

  @doc """
  Build a skill from its frontmatter and files.

  `frontmatter` must contain `name` and `description`; every other field passes through
  to clients as written. `files` maps paths relative to the skill's root to their
  contents, and must include `"SKILL.md"` without its frontmatter. Contents are iodata,
  or a function that returns iodata when the file is needed.
  """
  @spec new(map(), %{required(String.t()) => iodata() | (-> iodata())}) :: t()
  def new(frontmatter, files) do
    frontmatter = stringify_keys(frontmatter)
    files = Map.new(files, fn {path, content} -> {path, normalize_content(content)} end)

    validate_frontmatter!(frontmatter)
    Enum.each(Map.keys(files), &validate_path!/1)

    if not Map.has_key?(files, "SKILL.md") do
      raise ArgumentError, "a skill must have a SKILL.md file"
    end

    skill = %__MODULE__{frontmatter: frontmatter, files: files}
    validate_limits!(skill)
    skill
  end

  defp validate_path!(path) when is_binary(path) do
    if path |> String.split("/") |> Enum.any?(&invalid_segment?/1) do
      raise_invalid_path!(path)
    end
  end

  defp validate_path!(path), do: raise_invalid_path!(path)

  defp invalid_segment?(segment),
    do: segment in ["", ".", ".."] or String.contains?(segment, "\\")

  defp raise_invalid_path!(path) do
    raise ArgumentError,
          "invalid file path #{inspect(path)}: paths are relative to the skill's root, " <>
            "separated by /, without empty, . or .. segments or backslashes"
  end

  @doc """
  Mark a skill as generated such that its files can't have stable digests.

  Clients receive `"resources": "dynamic"` instead of a manifest, and some
  clients decline to load such skills.
  """
  @spec dynamic(t()) :: t()
  def dynamic(%__MODULE__{} = skill), do: %{skill | dynamic: true}

  @doc """
  Let clients cache the skill's `skills/list` and `skills/get` entries.

  Both `:ttl_ms` and `:scope` (`:public` or `:private`) are required, with the
  meaning of `Phantom.Request.with_cache/2`.
  """
  @spec with_cache(t(), ttl_ms: non_neg_integer(), scope: :public | :private) :: t()
  def with_cache(%__MODULE__{} = skill, opts) do
    with {:ok, ttl_ms} when is_integer(ttl_ms) and ttl_ms >= 0 <- Keyword.fetch(opts, :ttl_ms),
         {:ok, scope} when scope in [:public, :private] <- Keyword.fetch(opts, :scope) do
      %{skill | cache: [ttl_ms: ttl_ms, scope: scope]}
    else
      _ ->
        raise ArgumentError,
              "with_cache/2 requires :ttl_ms, a non-negative integer, and :scope, :public or :private"
    end
  end

  defp normalize_content(fun) when is_function(fun, 0), do: fun
  defp normalize_content(iodata), do: IO.iodata_to_binary(iodata)

  @doc """
  Compile every skill directory matching `pattern` into a function.

  The pattern is relative to the current file. A directory with a `SKILL.md` or
  `SKILL.md.eex` becomes a function named after the directory, with hyphens replaced
  by underscores, that takes assigns and returns a `%Phantom.Skill{}`.
  """
  defmacro embed_skills(pattern) do
    pattern = Path.expand(pattern, Path.dirname(__CALLER__.file))

    skill_dirs =
      pattern
      |> Path.wildcard()
      |> Enum.filter(
        &(File.exists?(Path.join(&1, "SKILL.md")) or File.exists?(Path.join(&1, "SKILL.md.eex")))
      )

    if skill_dirs == [] do
      raise ArgumentError, "no skills found matching #{pattern}"
    end

    quote do
      @phantom_skill_hashes {unquote(pattern), unquote(__files_hash__(pattern))}
      unquote_splicing(Enum.map(skill_dirs, &embed_skill/1))
    end
  end

  defp embed_skill(dir) do
    name = Path.basename(dir)
    files = dir |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)

    skill_md_path =
      Enum.find([Path.join(dir, "SKILL.md.eex"), Path.join(dir, "SKILL.md")], &File.exists?/1)

    {frontmatter, skill_md} = embed_skill_md(skill_md_path)

    embedded = [
      {"SKILL.md", skill_md}
      | for(path <- files, path != skill_md_path, do: embed_file(path, dir))
    ]

    embedded
    |> Enum.map(&elem(&1, 0))
    |> Enum.frequencies()
    |> Enum.each(fn
      {_path, 1} -> :ok
      {path, _} -> raise ArgumentError, "#{dir}: more than one file is served at #{path}"
    end)

    contents = for {path, content} <- embedded, do: {path, embed_content(content)}

    quote do
      unquote_splicing(Enum.map(files, &quote(do: @external_resource(unquote(&1)))))

      def unquote(function_name(name))(var!(assigns)) do
        _ = var!(assigns)

        Phantom.Skill.new(unquote(Macro.escape(frontmatter)), %{unquote_splicing(contents)})
      end
    end
  end

  defp embed_skill_md(path) do
    source = File.read!(path)

    {frontmatter, body} =
      case parse(source) do
        {:ok, frontmatter, body} -> {frontmatter, body}
        {:error, reason} -> raise ArgumentError, "#{path}: #{reason}"
      end

    header = binary_part(source, 0, byte_size(source) - byte_size(body))
    eex? = Path.extname(path) == ".eex"

    if eex? and String.contains?(header, "<%") do
      raise ArgumentError, "#{path}: EEx is not allowed in frontmatter"
    end

    validate_frontmatter!(frontmatter, path)

    name = path |> Path.dirname() |> Path.basename()

    if frontmatter["name"] != name do
      raise ArgumentError,
            "#{path}: frontmatter name #{inspect(frontmatter["name"])} must match its directory #{inspect(name)}"
    end

    content =
      if eex?,
        do: {:eex, EEx.compile_string(body, file: path, line: count_lines(header) + 1)},
        else: {:static, body}

    {frontmatter, content}
  end

  defp embed_content({:eex, quoted}), do: quote(do: fn -> unquote(quoted) end)
  defp embed_content({:static, iodata}), do: iodata

  defp embed_file(path, dir) do
    relative = Path.relative_to(path, dir)
    served_path = if Path.extname(relative) == ".eex", do: Path.rootname(relative), else: relative

    cond do
      # A nested SKILL.md keeps its frontmatter, because its own route serves the same bytes.
      Path.basename(served_path) == "SKILL.md" ->
        {frontmatter, {kind, body}} = embed_skill_md(path)
        {served_path, {kind, [frontmatter_block(frontmatter), body]}}

      Path.extname(relative) == ".eex" ->
        {served_path, {:eex, EEx.compile_file(path)}}

      true ->
        {served_path, {:static, File.read!(path)}}
    end
  end

  defp count_lines(text), do: text |> :binary.matches("\n") |> length()

  @doc false
  def __files_hash__(pattern) do
    pattern
    |> Path.wildcard()
    |> Enum.flat_map(&[&1 | Path.wildcard(Path.join(&1, "**/*"))])
    |> Enum.sort()
    |> :erlang.md5()
  end

  @doc """
  Split a `SKILL.md` into its parsed frontmatter and its body.
  """
  @spec parse(String.t()) :: {:ok, map(), String.t()} | {:error, String.t()}
  def parse(skill_md) do
    case Regex.named_captures(@frontmatter_pattern, skill_md) do
      %{"yaml" => yaml, "body" => body} ->
        with {:ok, frontmatter} <- parse_yaml(yaml), do: {:ok, frontmatter, body}

      nil ->
        {:error, "SKILL.md must begin with YAML frontmatter between --- lines"}
    end
  end

  defp parse_yaml(yaml) do
    if not Code.ensure_loaded?(:yamerl_constr) do
      raise "parsing SKILL.md frontmatter requires the :yamerl dependency, add {:yamerl, \"~> 0.10\"} to your deps"
    end

    try do
      :yamerl_constr.string(yaml, str_node_as_binary: true, map_node_format: :map)
    catch
      _kind, _reason -> {:error, "invalid YAML frontmatter"}
    else
      [%{} = frontmatter] -> {:ok, stringify_keys(frontmatter)}
      _ -> {:error, "frontmatter must be a YAML mapping"}
    end
  end

  @doc """
  The skill's files as served, with the frontmatter written ahead of `SKILL.md`.
  Renders every file.
  """
  @spec contents(t()) :: %{required(String.t()) => binary()}
  def contents(%__MODULE__{files: files} = skill) do
    Map.new(files, fn {path, _content} -> {path, render(skill, path)} end)
  end

  @doc false
  def render(%__MODULE__{frontmatter: frontmatter, files: files}, "SKILL.md"),
    do: frontmatter_block(frontmatter) <> render_content(files["SKILL.md"])

  def render(%__MODULE__{files: files}, path), do: render_content(files[path])

  defp render_content(fun) when is_function(fun, 0), do: IO.iodata_to_binary(fun.())
  defp render_content(binary), do: binary

  # YAML 1.2 parses each JSON value back to the same value.
  defp frontmatter_block(frontmatter) do
    {first, rest} = Map.split(frontmatter, ["name", "description"])

    lines =
      Enum.map(
        [{"name", first["name"]}, {"description", first["description"]} | Enum.sort(rest)],
        fn {key, value} -> [yaml_key(key), ": ", JSON.encode!(value), "\n"] end
      )

    IO.iodata_to_binary(["---\n", lines, "---\n"])
  end

  defp yaml_key(key) do
    if Regex.match?(@simple_key, key), do: key, else: JSON.encode!(key)
  end

  @doc false
  def validate_name!(name, context \\ "skill") do
    if not (is_binary(name) and String.length(name) in 1..64 and Regex.match?(@name_pattern, name)) do
      raise ArgumentError,
            "#{context}: invalid skill name #{inspect(name)}. Names are 1-64 lowercase " <>
              "letters, digits, and single hyphens, and do not start or end with a hyphen"
    end

    :ok
  end

  defp validate_frontmatter!(frontmatter, context \\ "skill") do
    validate_name!(frontmatter["name"], context)

    if not (is_binary(frontmatter["description"]) and
              String.length(frontmatter["description"]) in 1..1024) do
      raise ArgumentError, "#{context}: frontmatter must have a description of 1-1024 characters"
    end
  end

  # This check counts only static files, so that file functions stay lazy.
  defp validate_limits!(%__MODULE__{files: files}) do
    static_bytes = files |> Map.values() |> Enum.filter(&is_binary/1) |> Enum.map(&byte_size/1)

    case check_limits(map_size(files), Enum.sum(static_bytes)) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "a skill has #{reason}"
    end
  end

  @doc false
  def check_limits(file_count, _bytes) when file_count > @max_files,
    do: {:error, "more than #{@max_files} files"}

  def check_limits(_file_count, bytes) when bytes > @max_size,
    do: {:error, "more than #{@max_size} bytes of files"}

  def check_limits(_file_count, _bytes), do: :ok

  @doc false
  def function_name(skill_name), do: skill_name |> String.replace("-", "_") |> String.to_atom()

  defp stringify_keys(:null), do: nil

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(stringify_keys(k)), stringify_keys(v)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end

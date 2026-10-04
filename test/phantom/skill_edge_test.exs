defmodule Phantom.SkillEdgeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Phantom.Cache
  alias Phantom.Skill

  defmodule Actions do
    alias Phantom.Skill

    def outer(_params, session) do
      {:reply,
       Skill.new(%{name: "outer", description: "Outer skill"}, %{
         "SKILL.md" => "# Outer\n",
         "inner/notes.md" => "hello Ada\n",
         "gone/notes.md" => "kept\n"
       }), session}
    end

    def inner(_params, session) do
      {:reply,
       Skill.new(%{name: "inner", description: "Inner skill"}, %{
         "SKILL.md" => "# Inner\n",
         "notes.md" => "hello\n"
       }), session}
    end

    def gone(_params, session), do: {:reply, nil, session}

    def spaced_files(_params, session) do
      {:reply,
       Skill.new(%{name: "spaced-files", description: "A file with a space"}, %{
         "SKILL.md" => "# Spaced\n",
         "my file.md" => "spaced\n"
       }), session}
    end

    def buggy(_params, _session), do: String.upcase(Process.get(:missing))

    def exploding(_params, session) do
      {:reply,
       Skill.new(%{name: "exploding", description: "Raises when rendered"}, %{
         "SKILL.md" => fn -> raise "boom" end
       }), session}
    end

    def async_skill(_params, session), do: {:noreply, session}

    def fine(_params, session) do
      {:reply, Skill.new(%{name: "fine", description: "Fine"}, %{"SKILL.md" => "# Fine\n"}),
       session}
    end

    def pub(_params, session) do
      {:reply,
       Skill.new(%{name: "pub", description: "Public"}, %{"SKILL.md" => "# Pub\n"})
       |> Skill.with_cache(ttl_ms: 1_000, scope: :public), session}
    end

    def admin(_params, %{assigns: %{admin: true}} = session) do
      {:reply,
       Skill.new(%{name: "admin", description: "Admins only"}, %{"SKILL.md" => "# Admin\n"})
       |> Skill.with_cache(ttl_ms: 1_000, scope: :public), session}
    end

    def admin(_params, session), do: {:reply, nil, session}

    def featured_review(_params, session), do: review("featured", session)
    def review_by_id(%{"id" => id}, session), do: review("by id #{id}", session)

    defp review(text, session) do
      {:reply,
       Skill.new(%{name: "review", description: "Review"}, %{"SKILL.md" => "# #{text}\n"}),
       session}
    end

    def git_workflow(_params, session) do
      {:reply, Skill.new(%{name: "git-workflow", description: "Git"}, %{"SKILL.md" => "# Git\n"}),
       session}
    end

    def top(_params, session) do
      {:reply,
       Skill.new(%{name: "top", description: "Top skill"}, %{
         "SKILL.md" => "# Top\n",
         "mid/notes.md" => "top copy\n",
         "mid/bottom/notes.md" => "TOP COPY\n"
       }), session}
    end

    def mid(_params, session), do: {:reply, nil, session}

    def bottom(_params, session) do
      {:reply,
       Skill.new(%{name: "bottom", description: "Bottom skill"}, %{
         "SKILL.md" => "# Bottom\n",
         "notes.md" => "BOTTOM\n"
       }), session}
    end

    def raiser(_params, _session), do: raise("nested boom")

    def slow_skill(_params, session) do
      send(session.assigns.test, {:blocked, self()})

      receive do
        :go ->
          {:reply,
           Skill.new(%{name: "slow-skill", description: "Slow"}, %{"SKILL.md" => "# Slow\n"}),
           session}
      end
    end
  end

  defmodule NestRouter do
    use Phantom.Router, name: "Nest", vsn: "1.0"

    skill "nest/outer", Actions
    skill "nest/outer/inner", Actions
    skill "nest/outer/gone", Actions
    skill "files/spaced-files", Actions
    skill "git-workflow", Actions
    skill "deep/top", Actions
    skill "deep/top/mid", Actions
    skill "deep/top/mid/bottom", Actions
  end

  defmodule RaiseRouter do
    use Phantom.Router, name: "Raise", vsn: "1.0"

    skill "boom/outer", Actions
    skill "boom/outer/raiser", Actions
  end

  defmodule FailRouter do
    use Phantom.Router, name: "Fail", vsn: "1.0"

    skill "ok/fine", Actions
    skill "bugs/buggy", Actions
    skill "bugs/exploding", Actions
    skill "bad/async-skill", Actions
  end

  defmodule PublicRouter do
    use Phantom.Router, name: "Public", vsn: "1.0"

    skill "a/pub", Actions
    skill "z/admin", Actions
  end

  defmodule StaticFirstRouter do
    use Phantom.Router, name: "StaticFirst", vsn: "1.0"

    skill "studies/featured/review", Actions, :featured_review
    skill "studies/:id/review", Actions, :review_by_id
  end

  defmodule ParamFirstRouter do
    use Phantom.Router, name: "ParamFirst", vsn: "1.0"

    skill "studies/:id/review", Actions, :review_by_id
    skill "studies/featured/review", Actions, :featured_review
  end

  defmodule LateRouter do
    use Phantom.Router, name: "Late", vsn: "1.0"
  end

  defmodule ConcurrentRouter do
    use Phantom.Router, name: "Concurrent", vsn: "1.0"
  end

  defmodule PagedRouter do
    use Phantom.Router, name: "Paged", vsn: "1.0"
  end

  defmodule BatchRouter do
    use Phantom.Router, name: "Batch", vsn: "1.0"
  end

  defmodule InFlightRouter do
    use Phantom.Router, name: "InFlight", vsn: "1.0"
  end

  setup do
    for router <- [
          NestRouter,
          RaiseRouter,
          FailRouter,
          PublicRouter,
          StaticFirstRouter,
          ParamFirstRouter
        ],
        do: Cache.register(router)

    :ok
  end

  defp dispatch(router, method, params, opts \\ []) do
    session =
      Phantom.Test.build_session(router,
        assigns: Keyword.get(opts, :assigns, %{}),
        allowed_resource_templates: opts[:allowed_resource_templates]
      )

    request = Phantom.Test.build_request(method, params: params)
    router.dispatch_method(method, params, request, %{session | request: request})
  end

  defp read(router, uri, opts \\ []) do
    case dispatch(router, "resources/read", %{"uri" => uri}, opts) do
      {:reply, %{contents: [%{text: text}]}, _} -> {:ok, text}
      {:error, error, _} -> {:error, error}
    end
  end

  defp get(router, uri, opts \\ []), do: dispatch(router, "skills/get", %{"uri" => uri}, opts)

  defp sha256(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  describe "nested skills with their own route" do
    test "the parent's manifest lists the nested skill's files, matching what's read" do
      assert {:reply, %{skill: %{resources: resources}}, _} =
               get(NestRouter, "skill://nest/outer/SKILL.md")

      assert [
               "skill://nest/outer/SKILL.md",
               "skill://nest/outer/inner/SKILL.md",
               "skill://nest/outer/inner/notes.md"
             ] = Enum.map(resources, & &1.uri)

      for %{uri: uri, digest: digest, size: size} <- resources do
        assert {:ok, bytes} = read(NestRouter, uri)
        assert digest == sha256(bytes), uri
        assert size == byte_size(bytes), uri
      end

      assert {:ok, "hello\n"} = read(NestRouter, "skill://nest/outer/inner/notes.md")
    end

    test "files owned by a nested skill that serves none are neither listed nor read" do
      assert {:error, _} = read(NestRouter, "skill://nest/outer/gone/notes.md")
    end

    test "a deeper skill under an absent nested skill is still part of the manifest" do
      assert {:reply, %{skill: %{resources: resources}}, _} =
               get(NestRouter, "skill://deep/top/SKILL.md")

      assert [
               "skill://deep/top/SKILL.md",
               "skill://deep/top/mid/bottom/SKILL.md",
               "skill://deep/top/mid/bottom/notes.md"
             ] = Enum.map(resources, & &1.uri)

      for %{uri: uri, digest: digest, size: size} <- resources do
        assert {:ok, bytes} = read(NestRouter, uri)
        assert digest == sha256(bytes), uri
        assert size == byte_size(bytes), uri
      end

      assert {:ok, "BOTTOM\n"} = read(NestRouter, "skill://deep/top/mid/bottom/notes.md")
      assert {:error, _} = read(NestRouter, "skill://deep/top/mid/notes.md")
    end

    test "skills/get on a nested skill is allowed by the parent's permission" do
      assert {:reply, %{skill: %{frontmatter: %{"name" => "inner"}}}, _} =
               get(NestRouter, "skill://nest/outer/inner/SKILL.md",
                 allowed_resource_templates: ["nest/outer"]
               )
    end

    @tag :capture_log
    test "a nested action that raises fails skills/get, and is left out of skills/list" do
      assert_raise RuntimeError, "nested boom", fn ->
        get(RaiseRouter, "skill://boom/outer/SKILL.md")
      end

      assert {:reply, %{skills: []}, _} = dispatch(RaiseRouter, "skills/list", %{})
    end

    test "directory reads list the nested skill's files" do
      assert {:reply, %{resources: resources}, _} =
               dispatch(NestRouter, "resources/directory/read", %{
                 "uri" => "skill://nest/outer/inner"
               })

      assert [
               %{name: "inner", description: "Inner skill", mimeType: "text/markdown"},
               %{name: "notes.md"}
             ] = resources
    end

    test "the parent's permission covers the nested skill's files" do
      assert {:ok, "hello\n"} =
               read(NestRouter, "skill://nest/outer/inner/notes.md",
                 allowed_resource_templates: ["nest/outer"]
               )
    end

    test "the nested skill's permission does not cover the parent's files" do
      assert {:error, _} =
               read(NestRouter, "skill://nest/outer/SKILL.md",
                 allowed_resource_templates: ["nest/outer/inner"]
               )

      assert {:error, _} =
               read(NestRouter, "skill://nest/outer/gone/notes.md",
                 allowed_resource_templates: ["nest/outer/gone"]
               )
    end

    test "a skill's path params can't continue below another skill's path" do
      assert_raise ArgumentError, ~r/nested/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Phantom.SkillEdgeTest.BadNesting do
              use Phantom.Router, name: "BadNesting"
              skill "nest/outer", Phantom.SkillEdgeTest.Actions
              skill "nest/outer/:x/inner", Phantom.SkillEdgeTest.Actions
            end
          end
        )
      end
    end
  end

  describe "resources/read" do
    test "is limited by the session's allowed resource templates" do
      assert {:error, _} =
               read(NestRouter, "skill://nest/outer/SKILL.md",
                 allowed_resource_templates: ["git-workflow"]
               )
    end
  end

  describe "URIs" do
    test "percent-encodes file paths in manifests and reads them back" do
      assert {:reply, %{skill: %{resources: resources}}, _} =
               get(NestRouter, "skill://files/spaced-files/SKILL.md")

      assert "skill://files/spaced-files/my%20file.md" in Enum.map(resources, & &1.uri)
      assert {:ok, "spaced\n"} = read(NestRouter, "skill://files/spaced-files/my%20file.md")
    end

    test "only canonical URIs resolve, without logging errors" do
      log =
        capture_log(fn ->
          for uri <- [
                "skill://git-workflow/SKILL.md/",
                "skill://GIT-WORKFLOW/SKILL.md",
                "skill://git-workflow/SKILL.md?x=1",
                "skill://git-workflow//SKILL.md",
                "skill://git-workflow/%53KILL.md"
              ] do
            assert {:error, %{code: -32602}, _} = get(NestRouter, uri)
            assert {:error, _} = read(NestRouter, uri)
          end

          for uri <- ["skill://nest/outer/", "skill://nest/outer/inner/"] do
            assert {:error, %{code: -32602}, _} =
                     dispatch(NestRouter, "resources/directory/read", %{"uri" => uri})
          end
        end)

      refute log =~ "[error]"
    end

    test "the first segment of a skill path can't be a path param" do
      assert_raise ArgumentError, ~r/first segment/, fn ->
        Phantom.Router.skill_template(
          path: ":tenant/git-workflow",
          handler: Actions,
          router: __MODULE__
        )
      end
    end
  end

  describe "missing params" do
    test "skills/get and resources/directory/read require a uri" do
      assert {:error, %{code: -32602}, _} = dispatch(NestRouter, "skills/get", %{})

      assert {:error, %{code: -32602}, _} =
               dispatch(NestRouter, "resources/directory/read", %{})
    end
  end

  describe "failures" do
    test "a FunctionClauseError raised inside an action is not treated as no skill" do
      assert_raise FunctionClauseError, fn -> get(FailRouter, "skill://bugs/buggy/SKILL.md") end
    end

    test "skills/list omits skills whose action or files raise, and logs them" do
      log =
        capture_log(fn ->
          assert {:reply, %{skills: [%{uri: "skill://ok/fine/SKILL.md"}]}, _} =
                   dispatch(FailRouter, "skills/list", %{})
        end)

      assert log =~ "bugs/buggy"
      assert log =~ "bugs/exploding"
      assert log =~ "bad/async-skill"
    end

    test "an unsupported return value raises a descriptive error" do
      assert_raise ArgumentError, ~r/synchronous/, fn ->
        get(FailRouter, "skill://bad/async-skill/SKILL.md")
      end
    end
  end

  describe "public listings" do
    test "are public only when every skill on the page is served and public" do
      assert {:reply, %{skills: [_, _], cacheScope: "public"}, _} =
               dispatch(PublicRouter, "skills/list", %{}, assigns: %{admin: true})

      assert {:reply, %{skills: [%{uri: "skill://a/pub/SKILL.md"}], cacheScope: "private"}, _} =
               dispatch(PublicRouter, "skills/list", %{}, assigns: %{admin: false})
    end
  end

  describe "route precedence" do
    test "a static route wins over a path param at the same depth" do
      for router <- [StaticFirstRouter, ParamFirstRouter] do
        assert {:ok, "---" <> _ = text} = read(router, "skill://studies/featured/review/SKILL.md")
        assert text =~ "# featured"

        assert {:ok, text} = read(router, "skill://studies/42/review/SKILL.md")
        assert text =~ "# by id 42"
      end
    end
  end

  describe "Cache.add_skill/2" do
    test "keeps skills added before the router is registered" do
      Cache.add_skill(LateRouter, path: "late/git-workflow", handler: Actions)
      Cache.register(LateRouter)

      assert {:reply, %{skill: %{frontmatter: %{"name" => "git-workflow"}}}, _} =
               get(LateRouter, "skill://late/git-workflow/SKILL.md")
    end

    test "adds a list of skills" do
      Cache.add_skill(BatchRouter, [
        [path: "b1/git-workflow", handler: Actions],
        [path: "b2/git-workflow", handler: Actions]
      ])

      for uri <- ["skill://b1/git-workflow/SKILL.md", "skill://b2/git-workflow/SKILL.md"] do
        assert {:reply, %{skill: %{frontmatter: %{"name" => "git-workflow"}}}, _} =
                 get(BatchRouter, uri)
      end
    end

    test "waits for a read still running in the old routes" do
      Cache.add_skill(InFlightRouter,
        path: "slow/slow-skill",
        handler: Actions,
        function: :slow_skill
      )

      test = self()

      reader =
        Task.async(fn ->
          read(InFlightRouter, "skill://slow/slow-skill/SKILL.md", assigns: %{test: test})
        end)

      assert_receive {:blocked, action}

      Cache.add_skill(InFlightRouter, path: "one/git-workflow", handler: Actions)

      adding =
        Task.async(fn ->
          Cache.add_skill(InFlightRouter, path: "two/git-workflow", handler: Actions)
        end)

      Process.sleep(50)
      send(action, :go)

      assert {:ok, "---\n" <> _} = Task.await(reader)
      assert :ok = Task.await(adding)

      for uri <- ["skill://one/git-workflow/SKILL.md", "skill://two/git-workflow/SKILL.md"] do
        assert {:reply, %{skill: _}, _} = get(InFlightRouter, uri)
      end
    end

    test "logs compile errors from regenerating the routes" do
      log =
        capture_log(fn ->
          assert_raise CompileError, fn ->
            Cache.__redefine_modules__(fn ->
              Module.create(
                Phantom.SkillEdgeTest.Broken,
                quote(do: def(broken, do: undefined_variable)),
                __ENV__
              )
            end)
          end
        end)

      assert log =~ "undefined_variable"
    end

    test "keeps every skill added concurrently" do
      Cache.register(ConcurrentRouter)

      1..20
      |> Task.async_stream(fn i ->
        Cache.add_skill(ConcurrentRouter, path: "c#{i}/git-workflow", handler: Actions)
      end)
      |> Stream.run()

      assert 20 = length(Cache.list(nil, ConcurrentRouter, :resource_templates))
    end
  end

  describe "skills/list pagination" do
    test "pages through more than 100 skills" do
      Cache.register(PagedRouter)

      for i <- 1..105 do
        path = "p#{String.pad_leading(to_string(i), 3, "0")}/git-workflow"
        Cache.add_skill(PagedRouter, path: path, handler: Actions)
      end

      assert {:reply, %{skills: first, nextCursor: cursor}, _} =
               dispatch(PagedRouter, "skills/list", %{})

      assert {:reply, %{skills: rest} = second, _} =
               dispatch(PagedRouter, "skills/list", %{"cursor" => cursor})

      refute Map.has_key?(second, :nextCursor)
      assert length(first) == 100
      assert length(rest) == 5

      assert Enum.uniq(Enum.map(first ++ rest, & &1.uri)) |> length() == 105
    end
  end
end

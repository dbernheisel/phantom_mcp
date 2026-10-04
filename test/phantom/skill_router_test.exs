defmodule Phantom.SkillRouterTest do
  use ExUnit.Case, async: true

  alias Phantom.Cache

  defmodule Skills do
    use Phantom.Skill

    embed_skills "../support/skills/*"
    embed_skills "../support/skills/refunds/partial-refunds"

    def git_workflow(_params, session) do
      {:reply, git_workflow(%{}) |> Phantom.Skill.with_cache(ttl_ms: 300_000, scope: :public),
       session}
    end

    def refunds(_params, session),
      do: {:reply, refunds(%{user: session.assigns.user}), session}

    def partial_refunds(_params, session) do
      {:reply, partial_refunds(%{}) |> Phantom.Skill.with_cache(ttl_ms: 60_000, scope: :public),
       session}
    end

    def plain_strings(_params, session) do
      {:reply,
       Phantom.Skill.new(%{name: "plain-strings", description: "Only binaries"}, %{
         "SKILL.md" => "# Plain\n"
       }), session}
    end

    def study_review(%{"study_id" => "404"}, session), do: {:reply, nil, session}

    def study_review(%{"study_id" => id}, session),
      do: {:reply, study_review(%{study_id: id}), session}

    def daily(_params, session) do
      skill =
        Phantom.Skill.new(
          %{name: "daily", description: "Assemble today's report"},
          %{"SKILL.md" => "# Daily\n", "data/today.md" => "Today\n"}
        )

      {:reply, Phantom.Skill.dynamic(skill), session}
    end

    def mismatched(_params, session), do: {:reply, git_workflow(%{}), session}

    def lazy_skill(_params, session) do
      test = self()

      {:reply,
       Phantom.Skill.new(%{name: "lazy-skill", description: "Renders when read"}, %{
         "SKILL.md" => fn ->
           send(test, :rendered_skill_md)
           "# Lazy\n"
         end,
         "notes.md" => "Notes\n"
       }), session}
    end
  end

  defmodule TestRouter do
    use Phantom.Router, name: "SkillTest", vsn: "1.0"

    skill "git-workflow", Skills
    skill "acme/billing/refunds", Skills, :refunds
    skill "acme/billing/refunds/partial-refunds", Skills, :partial_refunds
    skill "studies/:study_id/study-review", Skills, :study_review
    skill "reports/daily", Skills, :daily
    skill "lazy/lazy-skill", Skills
    skill "plain/plain-strings", Skills
  end

  defmodule RuntimeRouter do
    use Phantom.Router, name: "RuntimeSkills", vsn: "1.0"
  end

  defmodule MismatchRouter do
    use Phantom.Router, name: "SkillMismatch", vsn: "1.0"

    skill "acme/wrong-name", Skills, :mismatched
  end

  defmodule EmptyRouter do
    use Phantom.Router, name: "NoSkills", vsn: "1.0"
  end

  setup do
    Cache.register(TestRouter)
    Cache.register(MismatchRouter)
    Cache.register(EmptyRouter)
    Cache.register(RuntimeRouter)
    :ok
  end

  defp dispatch(method, params, opts \\ []), do: dispatch_to(TestRouter, method, params, opts)

  defp dispatch_to(router, method, params, opts \\ []) do
    session =
      Phantom.Test.build_session(router,
        assigns: %{user: "Ada"},
        allowed_resource_templates: opts[:allowed_resource_templates]
      )

    request = Phantom.Test.build_request(method, params: params)
    router.dispatch_method(method, params, request, %{session | request: request})
  end

  defp sha256(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp read_bytes(uri) do
    assert {:reply, %{contents: [content]}, _} = dispatch("resources/read", %{"uri" => uri})

    case content do
      %{text: text} -> text
      %{blob: blob} -> Base.decode64!(blob)
    end
  end

  describe "skills/list" do
    test "lists every skill without path params, sorted by path" do
      assert {:reply, %{skills: skills, ttlMs: 0, cacheScope: "private"} = result, _} =
               dispatch("skills/list", %{})

      refute Map.has_key?(result, :nextCursor)

      assert [
               "skill://acme/billing/refunds/SKILL.md",
               "skill://acme/billing/refunds/partial-refunds/SKILL.md",
               "skill://git-workflow/SKILL.md",
               "skill://lazy/lazy-skill/SKILL.md",
               "skill://plain/plain-strings/SKILL.md",
               "skill://reports/daily/SKILL.md"
             ] = Enum.map(skills, & &1.uri)
    end

    test "entries carry the frontmatter and a complete manifest" do
      assert {:reply, %{skills: [refunds | _]}, _} = dispatch("skills/list", %{})

      assert %{
               frontmatter: %{"name" => "refunds", "license" => "Apache-2.0"},
               resources: [
                 %{uri: "skill://acme/billing/refunds/SKILL.md"},
                 %{uri: "skill://acme/billing/refunds/assets/logo.png"},
                 %{uri: "skill://acme/billing/refunds/examples/email.md"},
                 %{uri: "skill://acme/billing/refunds/partial-refunds/SKILL.md"}
               ]
             } = refunds
    end

    test "every digest and size matches the bytes resources/read returns" do
      assert {:reply, %{skills: skills}, _} = dispatch("skills/list", %{})

      for %{resources: resources} <- skills, is_list(resources), resource <- resources do
        bytes = read_bytes(resource.uri)
        assert resource.digest == sha256(bytes), resource.uri
        assert resource.size == byte_size(bytes), resource.uri
      end
    end

    test "dynamic skills have no manifest" do
      assert {:reply, %{skills: skills}, _} = dispatch("skills/list", %{})

      assert %{resources: "dynamic"} =
               Enum.find(skills, &(&1.uri == "skill://reports/daily/SKILL.md"))
    end

    test "respects the session's allowed resource templates" do
      assert {:reply, %{skills: [%{uri: "skill://git-workflow/SKILL.md"}]}, _} =
               dispatch("skills/list", %{}, allowed_resource_templates: ["git-workflow"])
    end

    test "is cached for the shortest ttl when every listed skill has cache hints" do
      assert {:reply, %{ttlMs: 60_000}, _} =
               dispatch("skills/list", %{},
                 allowed_resource_templates: [
                   "git-workflow",
                   "acme/billing/refunds/partial-refunds"
                 ]
               )
    end

    test "is private when the session has an allow-list" do
      assert {:reply, %{ttlMs: 300_000, cacheScope: "private"}, _} =
               dispatch("skills/list", %{}, allowed_resource_templates: ["git-workflow"])
    end
  end

  describe "skills/get" do
    test "returns the entry for a skill" do
      assert {:reply, %{skill: skill}, _} =
               dispatch("skills/get", %{"uri" => "skill://git-workflow/SKILL.md"})

      bytes = read_bytes("skill://git-workflow/SKILL.md")

      assert %{
               uri: "skill://git-workflow/SKILL.md",
               frontmatter: %{"name" => "git-workflow"},
               resources: [
                 %{uri: "skill://git-workflow/SKILL.md", digest: digest, size: size}
               ]
             } = skill

      assert digest == sha256(bytes)
      assert size == byte_size(bytes)
    end

    test "uses the skill's cache hints" do
      assert {:reply, %{ttlMs: 300_000, cacheScope: "public"}, _} =
               dispatch("skills/get", %{"uri" => "skill://git-workflow/SKILL.md"})
    end

    test "is private and not cached without cache hints, even when every file is a string" do
      for uri <- [
            "skill://plain/plain-strings/SKILL.md",
            "skill://acme/billing/refunds/SKILL.md",
            "skill://reports/daily/SKILL.md"
          ] do
        assert {:reply, %{ttlMs: 0, cacheScope: "private"}, _} =
                 dispatch("skills/get", %{"uri" => uri})
      end
    end

    test "renders every file for the manifest" do
      assert {:reply, %{skill: _}, _} =
               dispatch("skills/get", %{"uri" => "skill://lazy/lazy-skill/SKILL.md"})

      assert_received :rendered_skill_md
    end

    test "passes path params to the action" do
      assert {:reply, %{skill: %{frontmatter: %{"name" => "study-review"}}}, _} =
               dispatch("skills/get", %{"uri" => "skill://studies/42/study-review/SKILL.md"})

      assert read_bytes("skill://studies/42/study-review/SKILL.md") =~ "# Review study 42"
    end

    test "returns invalid params for an unknown skill" do
      for uri <- [
            "skill://acme/billing/chargebacks/SKILL.md",
            "skill://git-workflow/README.md",
            "skill://studies/404/study-review/SKILL.md",
            "https://example.com/SKILL.md"
          ] do
        assert {:error, %{code: -32602, message: "No skill is served at " <> ^uri}, _} =
                 dispatch("skills/get", %{"uri" => uri})
      end
    end

    test "respects the session's allowed resource templates" do
      assert {:error, %{code: -32602}, _} =
               dispatch("skills/get", %{"uri" => "skill://acme/billing/refunds/SKILL.md"},
                 allowed_resource_templates: ["git-workflow"]
               )
    end

    @tag :capture_log
    test "returns an internal error when the name does not match the path" do
      assert {:error, %{code: -32603}, _} =
               dispatch_to(MismatchRouter, "skills/get", %{
                 "uri" => "skill://acme/wrong-name/SKILL.md"
               })
    end
  end

  describe "resources/read" do
    test "serves SKILL.md with its frontmatter" do
      assert {:reply, %{contents: [content]}, _} =
               dispatch("resources/read", %{"uri" => "skill://acme/billing/refunds/SKILL.md"})

      assert %{
               uri: "skill://acme/billing/refunds/SKILL.md",
               mimeType: "text/markdown",
               text: "---\n" <> _ = text
             } = content

      assert {:ok, %{"name" => "refunds"}, "# Refunds\n\nHello Ada." <> _} =
               Phantom.Skill.parse(text)
    end

    test "serves binary files as blobs" do
      assert {:reply, %{contents: [%{mimeType: "image/png", blob: _}]}, _} =
               dispatch("resources/read", %{
                 "uri" => "skill://acme/billing/refunds/assets/logo.png"
               })
    end

    test "renders only the file being read" do
      assert read_bytes("skill://lazy/lazy-skill/notes.md") == "Notes\n"
      refute_received :rendered_skill_md
    end

    test "returns not found for a file the skill does not have" do
      assert {:error, %{code: _}, _} =
               dispatch("resources/read", %{"uri" => "skill://acme/billing/refunds/nope.md"})
    end
  end

  describe "resources/directory/read" do
    test "lists the direct children of a skill's root" do
      assert {:reply, %{resources: resources}, _} =
               dispatch("resources/directory/read", %{"uri" => "skill://acme/billing/refunds"})

      assert [
               %{
                 uri: "skill://acme/billing/refunds/SKILL.md",
                 name: "refunds",
                 description: "Process customer refund requests per company policy",
                 mimeType: "text/markdown"
               },
               %{
                 uri: "skill://acme/billing/refunds/assets",
                 name: "assets",
                 mimeType: "inode/directory"
               },
               %{
                 uri: "skill://acme/billing/refunds/examples",
                 name: "examples",
                 mimeType: "inode/directory"
               },
               %{
                 uri: "skill://acme/billing/refunds/partial-refunds",
                 name: "partial-refunds",
                 mimeType: "inode/directory"
               }
             ] = resources
    end

    test "lists a subdirectory" do
      assert {:reply,
              %{
                resources: [
                  %{uri: "skill://acme/billing/refunds/examples/email.md", name: "email.md"}
                ]
              }, _} =
               dispatch("resources/directory/read", %{
                 "uri" => "skill://acme/billing/refunds/examples"
               })
    end

    test "returns invalid params for a file or a missing directory" do
      for uri <- [
            "skill://acme/billing/refunds/SKILL.md",
            "skill://acme/billing/refunds/nope",
            "skill://acme/billing"
          ] do
        assert {:error, %{code: -32602}, _} =
                 dispatch("resources/directory/read", %{"uri" => uri})
      end
    end
  end

  describe "capabilities" do
    test "declares the skills extension and resources" do
      assert {:reply, %{capabilities: capabilities}, _} = dispatch("server/discover", %{})

      assert %{
               resources: %{},
               extensions: %{"io.modelcontextprotocol/skills" => %{directoryRead: true}}
             } = capabilities
    end

    test "omits the extension without skills" do
      assert {:reply, %{capabilities: capabilities}, _} =
               dispatch_to(EmptyRouter, "server/discover", %{})

      refute Map.has_key?(capabilities, :extensions)
    end
  end

  describe "Cache.add_skill/2" do
    test "serves a skill added at runtime" do
      Cache.add_skill(RuntimeRouter, path: "runtime/git-workflow", handler: Skills)

      assert {:reply, %{skill: %{frontmatter: %{"name" => "git-workflow"}}}, _} =
               dispatch_to(RuntimeRouter, "skills/get", %{
                 "uri" => "skill://runtime/git-workflow/SKILL.md"
               })

      assert {:reply, %{contents: [%{text: "---\n" <> _}]}, _} =
               dispatch_to(RuntimeRouter, "resources/read", %{
                 "uri" => "skill://runtime/git-workflow/SKILL.md"
               })

      assert {:reply, %{capabilities: %{extensions: %{"io.modelcontextprotocol/skills" => _}}}, _} =
               dispatch_to(RuntimeRouter, "server/discover", %{})
    end

    test "rejects an invalid skill path" do
      assert_raise ArgumentError, ~r/name/, fn ->
        Cache.add_skill(RuntimeRouter, path: "runtime/Bad_Name", handler: Skills, function: :x)
      end
    end
  end

  test "skill routes are generated in the router's ResourceRouter.Skill module" do
    assert Code.ensure_loaded?(TestRouter.ResourceRouter.Skill)
  end

  test "skill routes are not listed as resource templates" do
    assert {:reply, %{resourceTemplates: []}, _} = dispatch("resources/templates/list", %{})
  end

  test "the skill:// scheme is reserved for skills" do
    assert_raise RuntimeError, ~r/skill/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Phantom.SkillRouterTest.Reserved do
            use Phantom.Router, name: "Reserved"
            resource "skill://foo/:id", Phantom.SkillRouterTest.Skills, :git_workflow
          end
        end
      )
    end
  end

  test "skill paths must end in a valid skill name" do
    assert_raise ArgumentError, ~r/name/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Phantom.SkillRouterTest.BadPath do
            use Phantom.Router, name: "BadPath"
            skill "acme/:name", Phantom.SkillRouterTest.Skills, :git_workflow
          end
        end
      )
    end
  end
end

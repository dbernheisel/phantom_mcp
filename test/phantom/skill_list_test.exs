defmodule Phantom.SkillListTest do
  use ExUnit.Case, async: true

  alias Phantom.Cache
  alias Phantom.Skill

  defmodule Skills do
    alias Phantom.Skill

    def git_workflow(_params, session) do
      {:reply,
       Skill.new(%{name: "git-workflow", description: "Git"}, %{"SKILL.md" => "# Git\n"})
       |> Skill.with_cache(ttl_ms: 300_000, scope: :public), session}
    end

    def study_review(%{"study_id" => "404"}, session), do: {:reply, nil, session}

    def study_review(%{"study_id" => id}, session) do
      {:reply,
       Skill.new(%{name: "study-review", description: "Review a study"}, %{
         "SKILL.md" => "# Review study #{id}\n"
       })
       |> Skill.with_cache(ttl_ms: 60_000, scope: :public), session}
    end
  end

  defmodule CustomRouter do
    use Phantom.Router, name: "CustomList", vsn: "1.0"

    skill "git-workflow", Skills
    skill "studies/:study_id/study-review", Skills, :study_review

    def list_skills("fail", session), do: {:error, Phantom.Request.internal_error(), session}

    def list_skills("studies", session) do
      {:reply, Skill.list(["skill://studies/42/study-review/SKILL.md"], "more"), session}
    end

    def list_skills("unresolved", session) do
      uris = [
        "skill://git-workflow/SKILL.md",
        "skill://studies/404/study-review/SKILL.md",
        "skill://nope/SKILL.md",
        "skill://git-workflow/README.md"
      ]

      {:reply, Skill.list(uris, nil), session}
    end

    def list_skills(_cursor, session) do
      uris = ["skill://git-workflow/SKILL.md", "skill://studies/42/study-review/SKILL.md"]
      {:reply, Skill.list(uris, nil), session}
    end
  end

  defmodule DefaultRouter do
    use Phantom.Router, name: "DefaultList", vsn: "1.0"

    skill "git-workflow", Skills
    skill "studies/:study_id/study-review", Skills, :study_review
  end

  setup do
    Cache.register(CustomRouter)
    Cache.register(DefaultRouter)
    :ok
  end

  defp list(router, cursor, opts \\ []) do
    session =
      Phantom.Test.build_session(router,
        allowed_resource_templates: opts[:allowed_resource_templates]
      )

    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    request = Phantom.Test.build_request("skills/list", params: params)
    router.dispatch_method("skills/list", params, request, %{session | request: request})
  end

  defp uris(%{skills: skills}), do: Enum.map(skills, & &1.uri)

  test "Skill.list/2 omits nextCursor when there is no next page" do
    assert Skill.list(["skill://a/SKILL.md"], nil) == %{skills: ["skill://a/SKILL.md"]}

    assert Skill.list(["skill://a/SKILL.md"], "next") == %{
             skills: ["skill://a/SKILL.md"],
             nextCursor: "next"
           }
  end

  test "the default lists every skill route without path params" do
    assert {:reply, result, _} = list(DefaultRouter, nil)
    assert uris(result) == ["skill://git-workflow/SKILL.md"]
    assert %{ttlMs: 300_000, cacheScope: "public"} = result
  end

  test "the router can list a skill with path params" do
    assert {:reply, result, _} = list(CustomRouter, nil)

    assert uris(result) == [
             "skill://git-workflow/SKILL.md",
             "skill://studies/42/study-review/SKILL.md"
           ]

    assert %{ttlMs: 60_000, cacheScope: "public"} = result
  end

  test "the router can leave out a static skill and pass its cursor through" do
    assert {:reply, %{nextCursor: "more"} = result, _} = list(CustomRouter, "studies")
    assert uris(result) == ["skill://studies/42/study-review/SKILL.md"]
  end

  test "a URI that serves no skill is left out and makes the listing private" do
    assert {:reply, result, _} = list(CustomRouter, "unresolved")
    assert uris(result) == ["skill://git-workflow/SKILL.md"]
    assert %{ttlMs: 0, cacheScope: "private"} = result
    refute Map.has_key?(result, :nextCursor)
  end

  test "a URI the session may not use is left out and makes the listing private" do
    assert {:reply, result, _} =
             list(CustomRouter, nil, allowed_resource_templates: ["git-workflow"])

    assert uris(result) == ["skill://git-workflow/SKILL.md"]
    assert %{ttlMs: 0, cacheScope: "private"} = result
  end

  test "an error from the router is returned" do
    assert {:error, %{code: -32603}, _} = list(CustomRouter, "fail")
  end
end

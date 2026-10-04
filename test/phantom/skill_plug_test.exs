defmodule Phantom.SkillPlugTest do
  use ExUnit.Case, async: true

  import Phantom.TestDispatcher
  import Plug.Conn
  import Plug.Test

  defmodule Skills do
    alias Phantom.Skill

    def git_workflow(_params, session) do
      {:reply,
       Skill.new(%{name: "git-workflow", description: "Git"}, %{"SKILL.md" => "# Git\n"})
       |> Skill.with_cache(ttl_ms: 60_000, scope: :public), session}
    end
  end

  defmodule Router do
    use Phantom.Router, name: "SkillPlug", vsn: "1.0"

    skill "git-workflow", Skills
  end

  setup do
    Phantom.Cache.register(Router)
    :ok
  end

  defp post(id, method, params) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientInfo" => %{"name" => "Test", "version" => "1.0.0"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    :post
    |> conn("/mcp", %{
      jsonrpc: "2.0",
      id: id,
      method: method,
      params: Map.put(params, "_meta", meta)
    })
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", method)
    |> call(router: Router)

    assert_receive {:response, ^id, "message", payload}, 1_000
    payload
  end

  test "skills/list is served under 2026-07-28" do
    assert %{
             result: %{
               resultType: "complete",
               ttlMs: 60_000,
               cacheScope: "public",
               skills: [%{uri: "skill://git-workflow/SKILL.md"}]
             }
           } = post(1, "skills/list", %{})
  end

  test "skills/get is served under 2026-07-28" do
    assert %{
             result: %{
               resultType: "complete",
               ttlMs: 60_000,
               cacheScope: "public",
               skill: %{uri: "skill://git-workflow/SKILL.md"}
             }
           } = post(2, "skills/get", %{"uri" => "skill://git-workflow/SKILL.md"})
  end

  test "resources/directory/read is served under 2026-07-28" do
    assert %{
             result: %{
               resultType: "complete",
               resources: [%{uri: "skill://git-workflow/SKILL.md", name: "git-workflow"}]
             }
           } = post(3, "resources/directory/read", %{"uri" => "skill://git-workflow"})
  end
end

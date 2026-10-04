defmodule Phantom.SkillTest do
  use ExUnit.Case, async: true

  alias Phantom.Skill

  defmodule Embedded do
    use Phantom.Skill

    embed_skills "../support/skills/*"
    embed_skills "../support/skills/refunds/partial-refunds"
  end

  @skills_dir Path.expand("../support/skills", __DIR__)

  describe "new/2" do
    test "stringifies frontmatter keys and turns iodata into binaries" do
      assert %Skill{
               frontmatter: %{
                 "name" => "git-workflow",
                 "description" => "Git conventions",
                 "metadata" => %{"team" => "platform"}
               },
               files: %{"SKILL.md" => "# Git workflow\n"},
               dynamic: false
             } =
               Skill.new(
                 %{
                   name: "git-workflow",
                   description: "Git conventions",
                   metadata: %{team: "platform"}
                 },
                 %{"SKILL.md" => ["# Git ", "workflow\n"]}
               )
    end

    test "keeps functions to render when a file is needed" do
      skill =
        Skill.new(%{name: "a", description: "b"}, %{
          "SKILL.md" => fn -> ["# A", "\n"] end,
          "notes.md" => "Notes\n"
        })

      assert %Skill{files: %{"SKILL.md" => fun, "notes.md" => "Notes\n"}} = skill
      assert is_function(fun, 0)
      assert %{"SKILL.md" => "---\n" <> _, "notes.md" => "Notes\n"} = Skill.contents(skill)
      assert Skill.contents(skill)["SKILL.md"] =~ ~r/---\n# A\n\z/
    end

    test "rejects file paths that aren't relative paths within the skill" do
      for path <- ["", "/a.md", "a.md/", "a//b.md", "./a.md", "../a.md", "a/../b.md", "a\\b.md"] do
        assert_raise ArgumentError, ~r/path/, fn ->
          Skill.new(%{name: "a", description: "b"}, %{"SKILL.md" => "", path => ""})
        end
      end
    end

    test "requires a SKILL.md" do
      assert_raise ArgumentError, ~r/SKILL.md/, fn ->
        Skill.new(%{name: "a", description: "b"}, %{"README.md" => ""})
      end
    end

    test "requires a description" do
      assert_raise ArgumentError, ~r/description/, fn ->
        Skill.new(%{name: "a"}, %{"SKILL.md" => ""})
      end
    end

    test "enforces the Agent Skills naming rules" do
      for name <- [
            "Refunds",
            "-refunds",
            "refunds-",
            "re--funds",
            "re_funds",
            "",
            String.duplicate("a", 65)
          ] do
        assert_raise ArgumentError, ~r/name/, fn ->
          Skill.new(%{name: name, description: "b"}, %{"SKILL.md" => ""})
        end
      end
    end

    test "rejects skills with more than 512 files" do
      files = Map.new(1..512, &{"file-#{&1}.md", ""}) |> Map.put("SKILL.md", "")

      assert_raise ArgumentError, ~r/512/, fn ->
        Skill.new(%{name: "a", description: "b"}, files)
      end
    end
  end

  test "dynamic/1 marks a skill as dynamic" do
    skill = Skill.new(%{name: "a", description: "b"}, %{"SKILL.md" => ""})
    assert %Skill{dynamic: true} = Skill.dynamic(skill)
  end

  describe "with_cache/2" do
    test "skills have no cache hints unless given" do
      assert %Skill{cache: nil} = Skill.new(%{name: "a", description: "b"}, %{"SKILL.md" => ""})
    end

    test "stores the cache hints" do
      skill =
        %{name: "a", description: "b"}
        |> Skill.new(%{"SKILL.md" => ""})
        |> Skill.with_cache(ttl_ms: 60_000, scope: :public)

      assert %Skill{cache: [ttl_ms: 60_000, scope: :public]} = skill
    end

    test "requires a valid ttl and scope" do
      skill = Skill.new(%{name: "a", description: "b"}, %{"SKILL.md" => ""})

      for opts <- [
            [ttl_ms: 60_000],
            [scope: :public],
            [ttl_ms: -1, scope: :public],
            [ttl_ms: 1, scope: :shared]
          ] do
        assert_raise ArgumentError, fn -> Skill.with_cache(skill, opts) end
      end
    end
  end

  describe "embed_skills/1" do
    test "serves the same files as new/2, rendering EEx with assigns" do
      expected =
        Skill.new(
          %{
            "name" => "refunds",
            "description" => "Process customer refund requests per company policy",
            "license" => "Apache-2.0",
            "metadata" => %{"team" => "billing"}
          },
          %{
            "SKILL.md" =>
              "# Refunds\n\nHello Ada. Draft the reply from [the email template](examples/email.md).\n",
            "examples/email.md" => "# Email\n\nDear customer,\n",
            "assets/logo.png" => File.read!(Path.join(@skills_dir, "refunds/assets/logo.png")),
            "partial-refunds/SKILL.md" =>
              Skill.contents(Embedded.partial_refunds(%{}))["SKILL.md"]
          }
        )

      embedded = Embedded.refunds(%{user: "Ada"})
      assert embedded.frontmatter == expected.frontmatter
      assert Skill.contents(embedded) == Skill.contents(expected)
    end

    test "renders EEx files lazily and embeds other files as binaries" do
      assert %Skill{files: %{"SKILL.md" => skill_md, "examples/email.md" => "# Email" <> _}} =
               Embedded.refunds(%{user: "Ada"})

      assert is_function(skill_md, 0)
    end

    test "embeds static skills" do
      assert %Skill{
               frontmatter: %{
                 "name" => "git-workflow",
                 "description" => "Follow this team's Git conventions: branching and commits"
               },
               files: %{"SKILL.md" => "# Git workflow\n\nBranch from `main`.\n"}
             } = Embedded.git_workflow(%{})
    end

    test "embeds a nested skill on its own" do
      assert %Skill{frontmatter: %{"name" => "partial-refunds"}} = Embedded.partial_refunds(%{})
    end

    test "raises when the frontmatter name does not match the directory" do
      dir = Path.join(System.tmp_dir!(), "phantom-skill-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "refunds"))
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "refunds/SKILL.md"), "---\nname: other\ndescription: x\n---\n")

      assert_raise ArgumentError, ~r/other/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Phantom.SkillTest.Mismatch do
              use Phantom.Skill
              embed_skills unquote(Path.join(dir, "*"))
            end
          end
        )
      end
    end

    test "raises when two files are served at the same path" do
      dir = Path.join(System.tmp_dir!(), "phantom-skill-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "refunds"))
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "refunds/SKILL.md"), "---\nname: refunds\ndescription: x\n---\n")

      File.write!(
        Path.join(dir, "refunds/SKILL.md.eex"),
        "---\nname: refunds\ndescription: x\n---\n"
      )

      assert_raise ArgumentError, ~r/SKILL.md/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Phantom.SkillTest.Duplicate do
              use Phantom.Skill
              embed_skills unquote(Path.join(dir, "*"))
            end
          end
        )
      end
    end

    test "raises when EEx appears in the frontmatter" do
      dir = Path.join(System.tmp_dir!(), "phantom-skill-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "refunds"))
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(
        Path.join(dir, "refunds/SKILL.md.eex"),
        "---\nname: refunds\ndescription: <%= @x %>\n---\n"
      )

      assert_raise ArgumentError, ~r/frontmatter/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Phantom.SkillTest.EExFrontmatter do
              use Phantom.Skill
              embed_skills unquote(Path.join(dir, "*"))
            end
          end
        )
      end
    end
  end

  describe "parse/1" do
    test "stringifies keys that YAML parses as other types" do
      assert {:ok, %{"name" => "a", "1" => "x", "true" => %{"2" => "y"}}, ""} =
               Skill.parse("---\nname: a\n1: x\ntrue:\n  2: y\n---\n")
    end
  end

  describe "contents/1" do
    test "writes frontmatter that parses back to the same map" do
      frontmatter = %{
        "name" => "tricky",
        "description" => "Quotes \" and colons: here\nand a newline, unicode é ✓",
        "license" => nil,
        "allowed-tools" => "Bash(git:*) Read",
        "metadata" => %{"version" => 2, "ratio" => 1.5, "beta" => true, "tags" => ["a", "b: c"]}
      }

      skill = Skill.new(frontmatter, %{"SKILL.md" => "# Body\n"})
      %{"SKILL.md" => skill_md} = Skill.contents(skill)

      assert {:ok, ^frontmatter, "# Body\n"} = Skill.parse(skill_md)
    end
  end

  describe "embedded skills" do
    test "static files have digests computed at compile time" do
      assert %Skill{digests: %{"SKILL.md" => {_size, "sha256:" <> _}}} =
               Embedded.git_workflow(%{})

      assert %Skill{digests: digests} = Embedded.refunds(%{user: "Ada"})
      assert Map.has_key?(digests, "examples/email.md")
      refute Map.has_key?(digests, "SKILL.md")
    end
  end
end

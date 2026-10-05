# Skills

The [Skills extension](https://modelcontextprotocol.io/extensions/skills/overview)
(`io.modelcontextprotocol/skills`) serves [Agent Skills](https://agentskills.io/)
over MCP. A skill is a directory of files with a `SKILL.md` at its root: workflow
instructions an agent loads when it needs them, plus any references, templates,
or scripts they point to. Each file is a resource under `skill://`, so clients
read it with `resources/read`, list skills with `skills/list`, and verify them
with `skills/get`.

Phantom handles the protocol. You write the skills and decide who sees them:

| Phantom | You |
|---|---|
| Advertises the extension, with `directoryRead` | Route each skill to an action |
| Answers `skills/list`, `skills/get`, `resources/read`, and `resources/directory/read` from the action's result | Return the same files for the same session, or mark the skill dynamic |
| Writes `SKILL.md` frontmatter and computes each file's digest and size | Keep secrets and per-user data out of skills you mark public |
| Rejects non-canonical URIs and enforces the skill limits | Decide which skills `skills/list` returns, if not every static route |
| Applies the session's resource template allow-list | Return `nil` from an action for a skill the user may not see |

## Routing skills

Route a skill path to an action, the way a Phoenix router routes to a
controller. The last segment of the path is the skill's name; earlier segments
organize skills and may be path params, except the first:

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router, name: "MyApp", vsn: "1.0"

  # skill://git-workflow/SKILL.md → MyApp.MCP.Skills.git_workflow/2
  skill "git-workflow", MyApp.MCP.Skills

  skill "acme/billing/refunds", MyApp.MCP.Skills, :refunds
  skill "studies/:study_id/study-review", MyApp.MCP.Skills, :study_review
end
```

Names follow the Agent Skills rules: 1–64 lowercase letters, digits, and single
hyphens. The `skill://` scheme is reserved, so `resource "skill://..."` raises.

## Writing an action

An action receives the path params and the session, and returns
`{:reply, %Phantom.Skill{}, session}`. Return `{:reply, nil, session}` when no
skill is served at that path:

```elixir
def study_review(%{"study_id" => id}, session) do
  case MyApp.Studies.get(session.assigns.current_user, id) do
    nil -> {:reply, nil, session}
    study -> {:reply, study_review(%{study: study}), session}
  end
end
```

Phantom calls the same action for every method and serves the part each one
asks for. Actions are synchronous.

## Embedding skills from files

`embed_skills/1` compiles skill directories into functions, the way
`Phoenix.Component.embed_templates/1` compiles templates. Each directory with a
`SKILL.md` or `SKILL.md.eex` becomes a function named after it, with hyphens
replaced by underscores, that takes assigns:

```
lib/my_app/mcp/skills/
├── refunds/
│   ├── SKILL.md.eex
│   ├── examples/email.md
│   └── scripts/check.sh
└── study-review/
    └── SKILL.md.eex
```

```elixir
defmodule MyApp.MCP.Skills do
  use Phantom.Skill

  # refunds(assigns) and study_review(assigns)
  embed_skills "skills/*"

  def refunds(_params, session) do
    {:reply, refunds(%{user: session.assigns.current_user}), session}
  end
end
```

```markdown
---
name: refunds
description: Process customer refund requests per company policy
license: Apache-2.0
---
# Refunds

Draft the reply to <%= @user.name %> from [the email template](examples/email.md).
```

- Files ending in `.eex` render with assigns, and `.eex` is dropped from the
  served path. Other files are served as written.
- Frontmatter is parsed at compile time and must not contain EEx. Its `name`
  must match the directory.
- The module recompiles when skill files change, or when files are added or
  removed.

Parsing frontmatter requires the optional `:yamerl` dependency:

```elixir
{:yamerl, "~> 0.10"}
```

Use EEx, not HEEx, for skills: HEEx escapes values as HTML and rejects a bare
`<`, which is common in Markdown about code.

## Building skills in code

`Phantom.Skill.new/2` takes the frontmatter and the files, with `SKILL.md`
holding only the body. A file is iodata, or a function that returns iodata when
the file is needed:

```elixir
def git_workflow(_params, session) do
  {:reply,
   Phantom.Skill.new(
     %{name: "git-workflow", description: "Follow this team's Git conventions"},
     %{
       "SKILL.md" => "# Git workflow\n\nBranch from `main`. See [teams](references/teams.md).\n",
       "references/teams.md" => fn -> MyApp.Teams.markdown_table() end
     }
   ), session}
end
```

Phantom writes the frontmatter ahead of the body, so the frontmatter clients see
in `skills/list` always matches the `SKILL.md` they read. Any Markdown library
works, because files are iodata.

`resources/read` renders only the file it serves. `skills/list` and `skills/get`
render every file, because each entry lists every file's digest. Keep rendering
cheap, or cache it in your app.

A skill has at most 512 files and 16 MiB in total. File paths are relative to
the skill's root and may not contain `.` or `..` segments.

## Skills for each record

Path params give each record its own skill. The URI carries the ID, and the
action checks access like any other request:

```elixir
skill "studies/:study_id/study-review", MyApp.MCP.Skills, :study_review
```

A client can read `skill://studies/42/study-review/SKILL.md` directly, for
example when your server's instructions or a tool result points to it. Phantom
can't enumerate the IDs, so these skills aren't in `skills/list` until you list
them.

## Listing skills

`c:Phantom.Router.list_skills/2` decides which skills `skills/list` returns. By
default it lists every route without path params. Override it to list skills
for records, leave skills out, or page through your own data:

```elixir
def list_skills(cursor, session) do
  {studies, next_cursor} = MyApp.Studies.page(session.assigns.current_user, cursor)
  uris = Enum.map(studies, &"skill://studies/#{&1.id}/study-review/SKILL.md")

  {:reply, Phantom.Skill.list(["skill://git-workflow/SKILL.md" | uris], next_cursor),
   session}
end
```

Return `SKILL.md` URIs. Phantom builds each entry as `skills/get` does, and
leaves out a URI that serves no skill to the session. The cursor is opaque to
Phantom. The spec allows a partial listing, and clients can still get any skill
by URI.

## Nested skills

A skill routed under another skill's path is nested in it:

```elixir
skill "acme/billing/refunds", MyApp.MCP.Skills, :refunds
skill "acme/billing/refunds/partial-refunds", MyApp.MCP.Skills, :partial_refunds
```

Each file belongs to the deepest skill whose directory contains it. The parent's
manifest and directory listings take `partial-refunds/` from
`partial_refunds/2`, and leave out whatever the parent's own action has there.
So a client reading a parent's file always gets the bytes its manifest
describes.

- A nested action that returns `nil` or an error serves no files.
- A nested action that raises fails the parent's `skills/get`, and the parent is
  left out of `skills/list`.
- A route with path params can't be nested under another skill.

## Access

Each skill route is a resource template named by its path, so
`Phantom.Session.allow_resource_templates/2` limits skills too. A session allowed
a skill may use every skill nested in it:

```elixir
def connect(session, _auth_info) do
  {:ok, Phantom.Session.allow_resource_templates(session, ["git-workflow", "acme/billing/refunds"])}
end
```

Skill paths and resource template names share one namespace, so a skill can't
have the same path as a resource template's name. Skill routes are not listed in
`resources/templates/list`.

For checks that depend on the record, return `nil` from the action.

## Caching

`skills/list` and `skills/get` results are private and not cached, unless the
action declares cache hints with `Phantom.Skill.with_cache/2`:

```elixir
def git_workflow(_params, session) do
  {:reply, git_workflow(%{}) |> Phantom.Skill.with_cache(ttl_ms: 300_000, scope: :public),
   session}
end
```

Only declare `scope: :public` when the skill is the same for every user who can
see it. A listing is public only when every skill on the page is public, every
listed URI served a skill, and the session has no allow-list. It uses the
shortest `ttl_ms` of its skills.

## Dynamic skills

Digests let a client verify every file it reads against the entry it approved.
If an action can't return the same bytes for the same session, for example
because a file includes the current time, mark the skill dynamic:

```elixir
{:reply, Phantom.Skill.dynamic(skill), session}
```

Clients then receive `"resources": "dynamic"` instead of a manifest. Some
clients decline to load dynamic skills.

## Adding skills at runtime

`Phantom.Cache.add_skill/2` adds one skill, or a list, to a running router. Each
takes the same arguments as `Phantom.Router.skill/3`:

```elixir
Phantom.Cache.add_skill(MyApp.MCP.Router, [
  [path: "acme/support/escalations", handler: MyApp.MCP.Skills],
  [path: "acme/support/macros", handler: MyApp.MCP.Skills, function: :support_macros]
])
```

Each call regenerates the router's skill routes, so add skills in batches.

## Pointing to skills

A server's instructions or a tool result can name a skill by its URI. The
client confirms it with `skills/get` and reads it with `resources/read`, so
skills with path params work without being listed:

```elixir
use Phantom.Router,
  name: "MyApp",
  instructions: """
  Before editing a study, load skill://studies/{id}/study-review/SKILL.md.
  """
```

Skill content is instructions for a model, and hosts treat it as untrusted.
Hosts ignore frontmatter such as `allowed-tools` unless the user approves it,
so don't rely on it.

## Testing

Test an action like any other function, and check the files clients receive
with `Phantom.Skill.contents/1`:

```elixir
test "addresses the user" do
  user = insert(:user, name: "Ada")
  session = Phantom.Test.build_session(MyApp.MCP.Router, assigns: %{current_user: user})

  assert {:reply, skill, _session} = MyApp.MCP.Skills.refunds(%{}, session)
  assert %{"SKILL.md" => "---\n" <> _ = skill_md} = Phantom.Skill.contents(skill)
  assert skill_md =~ "Draft the reply to Ada"
end
```

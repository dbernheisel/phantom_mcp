# Prompts

Prompts are templated messages the user picks in the client, such as a slash
command. A prompt may take arguments; when it does, you may also provide a
completion function to help the client fill them in.

## Defining prompts

```elixir
defmodule MyApp.MCP.Router do
  use Phantom.Router, name: "MyApp", vsn: "1.0"

  @description """
  Review the provided Study and provide meaningful feedback about the
  study and let me know if there are gaps or missing questions. We want
  a meaningful study that can provide insight to the research goals stated
  in the study.
  """
  prompt :suggest_questions,
    completion_function: :study_complete,
    arguments: [
      %{
        name: "study_id",
        description: "The study to review",
        required: true
      }
    ]
end
```

See `Phantom.Prompt` and `Phantom.PromptArgument` for every option.

## Implementing prompts

A handler answers with `Phantom.Prompt.response/1`, a list of messages from
the `user` or the `assistant`.

### Synchronously

```elixir
require Phantom.Prompt, as: Prompt

def suggest_questions(%{"study_id" => study_id}, session) do
  case MyApp.MCP.Router.read_resource(session, :study, id: study_id) do
    {:ok, uri, resource} ->
      {:reply,
       Prompt.response(
         assistant: Prompt.embedded_resource(uri, resource),
         user: Prompt.text("Wowzers"),
         assistant: Prompt.image(File.read!("foo.png"), "image/png"),
         user: Prompt.text("Seriously, wowzers")
       ), session}

    _error ->
      {:error, Phantom.Request.internal_error(), session}
  end
end
```

### Asynchronously

```elixir
require Phantom.Prompt, as: Prompt
alias Phantom.Session

def suggest_questions(%{"study_id" => study_id}, session) do
  Task.async(fn ->
    case MyApp.MCP.Router.read_resource(session, :study, id: study_id) do
      {:ok, uri, resource} ->
        Session.respond(
          session,
          Prompt.response(
            assistant: Prompt.embedded_resource(uri, resource),
            user: Prompt.text("Wowzers")
          )
        )

      _error ->
        Session.respond(session, Phantom.Request.internal_error())
    end
  end)

  {:noreply, session}
end
```

## Completing arguments

The `completion_function` receives the argument's name, what the user has
typed so far, and the session:

```elixir
import Ecto.Query

def study_complete("study_id", value, session) do
  study_ids =
    Repo.all(
      from s in Study,
        select: s.id,
        where: like(type(s.id, :string), ^"#{value}%"),
        where: s.account_id == ^session.assigns.user.account_id,
        order_by: s.id,
        limit: 101
    )

  # You may also return a map with more info:
  # `%{values: study_ids, has_more: true, total: 1_000_000}`
  # If you return more than 100, then Phantom will set `has_more: true`
  # and only return the first 100.
  {:reply, study_ids, session}
end
```

Resource templates use completion functions the same way; see
[Resources](resources.md).

## Limiting prompts per session

By default every prompt is listed. To limit them, call
`Phantom.Session.allow_prompts/2` in `c:Phantom.Router.connect/2`; return
`allow_prompts(session, [])` to disable prompts.

## Adding prompts at runtime

Use `Phantom.Cache.add_prompt/2`; Phantom notifies clients with
`notifications/prompts/list_changed`.

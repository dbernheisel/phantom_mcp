defmodule Phantom.A2A.Agent do
  @moduledoc """
  Implement an A2A agent, served from a `Phantom.Router` with `agent`.

      defmodule MyApp.Agents.Research do
        use Phantom.A2A.Agent,
          name: "MyApp Research",
          description: "Designs and reviews research studies",
          input_modes: ~w[text/plain application/json],
          output_modes: ~w[text/markdown]

        alias Phantom.A2A.{Message, Task}

        @description "Review a study and suggest missing questions"
        skill :study_review, tags: ~w[research], examples: ["Review study 42"]

        def handle_message(message, ctx) do
          {:ok, _job} = MyApp.Reviews.start(ctx.task_ref, message, ctx.assigns.user)
          {:reply, Task.submitted(ctx), ctx}
        end

        def get_task(task_id, ctx), do: MyApp.Reviews.get_a2a_task(task_id, ctx.assigns.user)
      end

  ## Options

    * `:name` - the agent's name (required)
    * `:description` - what the agent does (required)
    * `:version` - the agent's version (default: the router's `:vsn`)
    * `:input_modes` - media types the agent accepts (default `["text/plain"]`),
      any MIME type, such as `"application/json"`, `"image/png"`, or
      `"application/pdf"`. Phantom rejects a message with a part whose
      `media_type` isn't listed; parts without a media type are accepted.
    * `:output_modes` - media types the agent produces (default
      `["text/plain"]`). Only advertised: a client may ask for some of them
      with `acceptedOutputModes`, in `ctx.configuration`.
    * `:documentation_url`, `:icon_url` - shown on the card
    * `:push_notifications` - whether the agent pushes task updates to
      clients' webhooks (default `false`). See "Push notifications".
    * `:extensions` - protocol extensions the agent supports, as maps with
      `:uri`, and optionally `:description`, `:required`, and `:params`.
      Phantom refuses requests that don't name a required extension in their
      `A2A-Extensions` header, and gives the handler the requested ones in
      `ctx.extensions`.
    * `:extended_card` - whether authenticated clients can fetch a fuller
      card with `GetExtendedAgentCard` (default `false`). See
      `c:extended_card/2`.

  ## Skills

  `skill` lists something the agent can do on its card. It reads
  `@description`, or takes `:description`, plus `:name`, `:tags`, `:examples`,
  `:input_modes`, and `:output_modes`. Skills only describe the agent: every
  message goes to `c:handle_message/2`.

  ## Push notifications

  With `push_notifications: true`, clients can register webhooks for a task,
  and Phantom pushes each event you publish to them. Store configs with
  `c:create_push_config/2` and its siblings, and return a task's configs from
  `c:push_configs/1`. See `Phantom.A2A.Push` for how webhooks are checked and
  called.

  ## Tasks

  Phantom doesn't store tasks. Implement `c:get_task/2` to return them; it is
  also where access is checked, so return `{:error, :not_found}` for tasks the
  session may not see. A client continues a task by sending a message with its
  `taskId`; Phantom checks it with `c:get_task/2` first. Report progress from
  wherever the work runs: save each event with `Phantom.A2A.Events.apply/2`,
  then send the event it returns with `Phantom.A2A.publish/2`. Phantom forwards each
  event to `SendStreamingMessage` and `SubscribeToTask` streams, and closes
  them when the task finishes or needs the client.
  """

  alias Phantom.A2A.{Card, Context, Error, Message, PushConfig, Task, TaskRef}

  @doc """
  Answer a client's message with a `Phantom.A2A.Message`, or with a
  `Phantom.A2A.Task` whose ID is `ctx.task_ref.task_id`.
  """
  @callback handle_message(Message.t(), Context.t()) ::
              {:reply, Message.t() | Task.t(), Context.t()} | {:error, Error.t(), Context.t()}

  @doc """
  Fetch a task the session may see. The default finds no tasks, for an agent
  that only answers with messages.
  """
  @callback get_task(task_id :: String.t(), Context.t()) :: {:ok, Task.t()} | {:error, :not_found}

  @doc "Cancel a task. By default, tasks can't be canceled."
  @callback cancel_task(Task.t(), Context.t()) :: {:ok, Task.t()} | {:error, :not_cancelable}

  @typedoc """
  The `ListTasks` filter. `page_size` is from 1 to 100 (default 50), and the
  others are `nil` when the client didn't send them.
  """
  @type list_filter :: %{
          context_id: String.t() | nil,
          status: Phantom.A2A.TaskStatus.state() | nil,
          page_size: pos_integer(),
          page_token: String.t() | nil,
          status_timestamp_after: DateTime.t() | nil
        }

  @doc """
  List the tasks the session may see that match the filter, newest first.
  By default, `ListTasks` is not supported.

  Return at most `page_size` tasks, and a `next_page_token` for the next page,
  or `nil` on the last one. Phantom trims history and artifacts as the client
  asked.
  """
  @callback list_tasks(list_filter(), Context.t()) ::
              {:ok,
               %{
                 required(:tasks) => [Task.t()],
                 optional(:next_page_token) => String.t() | nil,
                 optional(:total_size) => non_neg_integer()
               }}
              | {:error, Error.t()}

  @doc """
  Save a push notification config for a task the session may see. Phantom
  has checked the task with `c:get_task/2` and the URL, and given the config
  an ID.
  """
  @callback create_push_config(PushConfig.t(), Context.t()) ::
              {:ok, PushConfig.t()} | {:error, Error.t()}

  @doc "Fetch a task's push notification config"
  @callback get_push_config(task_id :: String.t(), id :: String.t(), Context.t()) ::
              {:ok, PushConfig.t()} | {:error, :not_found | Error.t()}

  @doc "List a task's push notification configs"
  @callback list_push_configs(task_id :: String.t(), Context.t()) ::
              {:ok, [PushConfig.t()]} | {:error, Error.t()}

  @doc "Delete a task's push notification config. Deleting a missing one is `:ok`."
  @callback delete_push_config(task_id :: String.t(), id :: String.t(), Context.t()) ::
              :ok | {:error, Error.t()}

  @doc """
  The configs to push an event to. `Phantom.A2A.publish/2` calls it, in the
  process that publishes, which has no session. Defaults to none.
  """
  @callback push_configs(TaskRef.t()) :: [PushConfig.t()]

  @doc """
  Deliver an event to a webhook. The default sends it in a supervised process
  with `Phantom.A2A.Push.deliver/3`, without retries. Override it to deliver
  from a job queue that retries, such as Oban.
  """
  @callback deliver_push(PushConfig.t(), Phantom.A2A.event(), TaskRef.t()) :: :ok

  @doc """
  Adjust the agent's card for its route, given the card from `use` and the
  route's router and options. Defaults to the card as it is.

      # agent "support-es", MyApp.Agents.Support, locale: "es"
      def card(card, %{opts: opts}), do: %{card | name: "Support (\#{opts[:locale]})"}
  """
  @callback card(Card.t(), %{router: module(), opts: keyword()}) :: Card.t()

  @doc """
  The card for `GetExtendedAgentCard`, given the public card, such as with
  skills only members may see. The request has passed
  `c:Phantom.Router.connect/2`. Return an error to refuse it. Defaults to the
  public card.
  """
  @callback extended_card(Card.t(), Context.t()) :: {:ok, Card.t()} | {:error, Error.t()}

  defmacro __using__(opts) do
    quote location: :keep, generated: true do
      @behaviour Phantom.A2A.Agent
      import Phantom.A2A.Agent, only: [skill: 1, skill: 2]

      @impl Phantom.A2A.Agent
      def get_task(_task_id, _ctx), do: {:error, :not_found}

      @impl Phantom.A2A.Agent
      def cancel_task(_task, _ctx), do: {:error, :not_cancelable}

      @impl Phantom.A2A.Agent
      def list_tasks(_filter, _ctx),
        do: {:error, Phantom.A2A.Error.unsupported_operation("Listing tasks is not supported")}

      @impl Phantom.A2A.Agent
      def create_push_config(_config, _ctx),
        do: {:error, Phantom.A2A.Error.push_notification_not_supported()}

      @impl Phantom.A2A.Agent
      def get_push_config(_task_id, _id, _ctx),
        do: {:error, Phantom.A2A.Error.push_notification_not_supported()}

      @impl Phantom.A2A.Agent
      def list_push_configs(_task_id, _ctx),
        do: {:error, Phantom.A2A.Error.push_notification_not_supported()}

      @impl Phantom.A2A.Agent
      def delete_push_config(_task_id, _id, _ctx),
        do: {:error, Phantom.A2A.Error.push_notification_not_supported()}

      @impl Phantom.A2A.Agent
      def push_configs(_task_ref), do: []

      @impl Phantom.A2A.Agent
      def deliver_push(config, event, task_ref),
        do: Phantom.A2A.Push.deliver_async(config, event, task_ref)

      @impl Phantom.A2A.Agent
      def extended_card(card, _ctx), do: {:ok, card}

      @impl Phantom.A2A.Agent
      def card(card, _route), do: card

      defoverridable card: 2,
                     extended_card: 2,
                     get_task: 2,
                     cancel_task: 2,
                     list_tasks: 2,
                     create_push_config: 2,
                     get_push_config: 3,
                     list_push_configs: 2,
                     delete_push_config: 3,
                     push_configs: 1,
                     deliver_push: 3

      @before_compile Phantom.A2A.Agent
      @phantom_a2a_opts unquote(opts)
      Module.register_attribute(__MODULE__, :phantom_a2a_skills, accumulate: true)
    end
  end

  @doc "List a skill on the agent's card. See the moduledoc."
  defmacro skill(id, opts \\ []) do
    quote generated: true do
      description = Module.delete_attribute(__MODULE__, :description)

      @phantom_a2a_skills Phantom.A2A.AgentSkill.build(
                            unquote(id),
                            Keyword.put_new(unquote(opts), :description, description)
                          )
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :phantom_a2a_opts)

    for key <- [:name, :description], not is_binary(opts[key]) do
      raise ArgumentError, "use Phantom.A2A.Agent requires a #{inspect(key)} string"
    end

    quote generated: true do
      @doc false
      def __phantom_a2a__(:push_notifications),
        do: Keyword.get(@phantom_a2a_opts, :push_notifications, false)

      def __phantom_a2a__(:extended_card),
        do: Keyword.get(@phantom_a2a_opts, :extended_card, false)

      def __phantom_a2a__(:card) do
        opts = @phantom_a2a_opts

        %Phantom.A2A.Card{
          name: opts[:name],
          description: opts[:description],
          version: opts[:version],
          documentation_url: opts[:documentation_url],
          icon_url: opts[:icon_url],
          default_input_modes: Keyword.get(opts, :input_modes, ["text/plain"]),
          default_output_modes: Keyword.get(opts, :output_modes, ["text/plain"]),
          skills: Enum.reverse(@phantom_a2a_skills),
          extensions: Keyword.get(opts, :extensions, [])
        }
      end
    end
  end
end

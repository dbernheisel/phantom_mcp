defmodule Phantom.A2A.Context do
  @moduledoc """
  The request an A2A agent handler is answering.

    * `:session` - the `Phantom.Session` returned by `c:Phantom.Router.connect/2`
    * `:assigns` - `session.assigns`
    * `:agent` - `%{id: id, opts: opts, params: params, state: state}`: the
      agent's path, the options of its `agent` route, and for a route with
      path params, the params and the state its resolver returned
    * `:message` - the client's `Phantom.A2A.Message`, for `SendMessage`
    * `:task_ref` - the `Phantom.A2A.TaskRef` of the task the request is
      about: the one a message creates or continues, or the one fetched,
      canceled, or subscribed to. A new task must use `task_ref.task_id` as
      its ID.
    * `:context_id` - the message's context, or a new one
    * `:tenant` - the request's `tenant`, passed through. A2A lets one
      endpoint serve several tenants, such as customer organizations: a
      card's interface names a tenant, and clients send it with each request.
      Phantom routes on the agent path, not the tenant. It is the client's
      claim: check it in `c:Phantom.Router.connect/2`, which sees it in
      `conn.body_params["params"]["tenant"]`, and assign what the session may
      use, such as its organization.
    * `:metadata` - the request's `metadata`
    * `:configuration` - the `SendMessage` configuration, as sent
  """

  alias Phantom.A2A.{Message, TaskRef}

  defstruct [
    :session,
    :agent,
    :message,
    :task_ref,
    :context_id,
    :tenant,
    :metadata,
    assigns: %{},
    configuration: %{}
  ]

  @type t :: %__MODULE__{
          session: Phantom.Session.t(),
          agent: %{id: String.t(), opts: keyword(), params: map(), state: term()},
          message: Message.t() | nil,
          task_ref: TaskRef.t() | nil,
          context_id: String.t() | nil,
          tenant: String.t() | nil,
          metadata: map() | nil,
          assigns: map(),
          configuration: map()
        }
end

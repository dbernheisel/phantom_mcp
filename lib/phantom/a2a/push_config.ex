defmodule Phantom.A2A.PushConfig do
  @moduledoc """
  Where to push a task's updates: a client's webhook `url`, with an optional
  `token` and `authentication` to send with each request.

  The agent stores configs; see the push callbacks of `Phantom.A2A.Agent`.
  """

  import Phantom.Utils, only: [remove_nils: 1]

  @enforce_keys [:url]
  defstruct [:id, :task_id, :url, :token, :authentication, :tenant]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          task_id: String.t() | nil,
          url: String.t(),
          token: String.t() | nil,
          authentication: %{scheme: String.t(), credentials: String.t() | nil} | nil,
          tenant: String.t() | nil
        }

  @doc false
  def from_json(%{"url" => url} = json) when is_binary(url) do
    with {:ok, authentication} <- authentication(json["authentication"]) do
      {:ok,
       %__MODULE__{
         id: json["id"],
         task_id: json["taskId"],
         url: url,
         token: json["token"],
         authentication: authentication,
         tenant: json["tenant"]
       }}
    end
  end

  def from_json(_json), do: {:error, "push notification config needs a url"}

  defp authentication(nil), do: {:ok, nil}

  defp authentication(%{"scheme" => scheme} = json) when is_binary(scheme),
    do: {:ok, %{scheme: scheme, credentials: json["credentials"]}}

  defp authentication(_json), do: {:error, "authentication needs a scheme"}

  @doc false
  def to_json(%__MODULE__{} = config) do
    remove_nils(%{
      "id" => config.id,
      "taskId" => config.task_id,
      "url" => config.url,
      "token" => config.token,
      "tenant" => config.tenant,
      "authentication" =>
        config.authentication &&
          remove_nils(%{
            "scheme" => config.authentication.scheme,
            "credentials" => config.authentication.credentials
          })
    })
  end
end

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
    with :ok <- check_strings(json),
         {:ok, authentication} <- authentication(json["authentication"]) do
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

  defp check_strings(json) do
    cond do
      not Enum.all?(~w[id taskId token tenant], &(is_nil(json[&1]) or is_binary(json[&1]))) ->
        {:error, "push notification config has a field of the wrong type"}

      not header_value?(json["token"]) ->
        {:error, "push notification token has a line break"}

      true ->
        :ok
    end
  end

  defp authentication(nil), do: {:ok, nil}

  defp authentication(%{"scheme" => scheme, "credentials" => credentials})
       when is_binary(scheme) and (is_binary(credentials) or is_nil(credentials)) do
    if header_value?(scheme) and header_value?(credentials),
      do: {:ok, %{scheme: scheme, credentials: credentials}},
      else: {:error, "authentication has a line break"}
  end

  defp authentication(%{"scheme" => scheme} = json)
       when is_binary(scheme) and not is_map_key(json, "credentials"),
       do: authentication(Map.put(json, "credentials", nil))

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

  # These values go into webhook request headers.
  defp header_value?(nil), do: true
  defp header_value?(value), do: not String.contains?(value, ["\r", "\n", <<0>>])
end

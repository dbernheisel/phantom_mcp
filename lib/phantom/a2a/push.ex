defmodule Phantom.A2A.Push do
  @moduledoc """
  Delivers A2A push notifications: each event about a task is `POST`ed as
  JSON to the task's webhooks.

  A webhook URL comes from a client, so Phantom checks it when a config is
  created and again before each delivery: it must use `https`, and every
  address its host resolves to must be public, so a client can't make the
  agent call into its own network. Delivery connects to the address that was
  checked, doesn't follow redirects, and sends:

    * `Authorization` - the config's `authentication`, such as `Bearer secret`
    * `X-A2A-Notification-Token` - the config's `token`

  Set `a2a: [allow_private_push_urls: true]` on the router to allow `http` and
  private addresses, such as in development.
  """

  require Logger
  import Bitwise

  alias Phantom.A2A.{PushConfig, TaskRef}

  @timeout :timer.seconds(10)

  @doc """
  Check a webhook URL.

  ## Options

    * `:allow_private_networks` - allow `http` and private addresses
  """
  @spec validate_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_url(url, opts \\ []) do
    with {:ok, _uri, _addresses} <- resolve(url, opts), do: :ok
  end

  @doc """
  Deliver an event to a webhook and wait for the answer. Returns `:ok` for a
  2xx answer. Takes the options of `validate_url/2`.
  """
  @spec deliver(PushConfig.t(), Phantom.A2A.event(), keyword()) :: :ok | {:error, term()}
  def deliver(%PushConfig{} = config, event, opts \\ []) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])

    with {:ok, uri, [address | _]} <- resolve(config.url, opts) do
      request = {
        address_url(uri, address),
        headers(config, uri),
        ~c"application/json",
        JSON.encode!(Phantom.A2A.event_to_json(event))
      }

      http_opts = [timeout: @timeout, connect_timeout: @timeout, autoredirect: false] ++ ssl(uri)

      case :httpc.request(:post, request, http_opts, body_format: :binary) do
        {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 -> :ok
        {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, {:status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  # The default `c:Phantom.A2A.Agent.deliver_push/3`.
  def deliver_async(%PushConfig{} = config, event, %TaskRef{router: router}) do
    opts = [
      allow_private_networks: router.__phantom__(:info).a2a[:allow_private_push_urls] == true
    ]

    {:ok, _pid} =
      Task.Supervisor.start_child(Phantom.A2A.PushSupervisor, fn ->
        with {:error, reason} <- deliver(config, event, opts) do
          Logger.warning("A2A push to #{config.url} failed: #{inspect(reason)}")
        end
      end)

    :ok
  end

  defp resolve(url, opts) do
    allow_private? = Keyword.get(opts, :allow_private_networks, false)

    with {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(host) and host != "" <-
           URI.new(url),
         :ok <- check_scheme(scheme, allow_private?),
         {:ok, addresses} <- addresses(host),
         :ok <- check_addresses(addresses, allow_private?) do
      {:ok, uri, addresses}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "is not a valid URL"}
    end
  end

  defp check_scheme("https", _allow_private?), do: :ok
  defp check_scheme("http", true), do: :ok
  defp check_scheme(_scheme, _allow_private?), do: {:error, "must use https"}

  defp addresses(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]") |> to_charlist()

    case :inet.parse_address(host) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _} ->
        case Enum.flat_map([:inet, :inet6], &lookup(host, &1)) do
          [] -> {:error, "has a host that doesn't resolve"}
          addresses -> {:ok, addresses}
        end
    end
  end

  defp lookup(host, family) do
    case :inet.getaddrs(host, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  defp check_addresses(_addresses, true), do: :ok

  defp check_addresses(addresses, false) do
    if Enum.any?(addresses, &private?/1),
      do: {:error, "resolves to a private address"},
      else: :ok
  end

  # Loopback, private, link-local, shared (CGNAT), benchmarking, multicast,
  # and reserved ranges, which no webhook should need.
  defp private?({a, b, c, _d}) do
    a in [0, 10, 127] or a >= 224 or
      (a == 100 and b in 64..127) or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 168) or
      (a == 192 and b == 0 and c in [0, 2]) or
      (a == 198 and b in 18..19)
  end

  defp private?({0, 0, 0, 0, 0, 0, 0, a}) when a in [0, 1], do: true
  defp private?({0, 0, 0, 0, 0, 0xFFFF, x, y}), do: private?(v4(x, y))
  defp private?({0x64, 0xFF9B, 0, 0, 0, 0, x, y}), do: private?(v4(x, y))

  defp private?({first, _, _, _, _, _, _, _}) do
    (first &&& 0xFE00) == 0xFC00 or (first &&& 0xFFC0) == 0xFE80 or
      (first &&& 0xFF00) == 0xFF00
  end

  defp v4(x, y), do: {x >>> 8, x &&& 0xFF, y >>> 8, y &&& 0xFF}

  # Connect to the address that was checked, so a second DNS lookup can't
  # point the request elsewhere. TLS still checks the certificate for the host.
  defp address_url(uri, address) do
    host =
      case :inet.ntoa(address) |> to_string() do
        host when tuple_size(address) == 8 -> "[#{host}]"
        host -> host
      end

    %{uri | host: host} |> URI.to_string() |> to_charlist()
  end

  defp headers(config, uri) do
    host =
      if uri.port == URI.default_port(uri.scheme), do: uri.host, else: "#{uri.host}:#{uri.port}"

    [{~c"host", to_charlist(host)}]
    |> add_header(~c"authorization", authorization(config.authentication))
    |> add_header(~c"x-a2a-notification-token", config.token)
  end

  defp authorization(%{scheme: scheme, credentials: credentials}) when is_binary(credentials),
    do: "#{scheme} #{credentials}"

  defp authorization(_authentication), do: nil

  defp add_header(headers, _name, nil), do: headers
  defp add_header(headers, name, value), do: [{name, to_charlist(value)} | headers]

  defp ssl(%URI{scheme: "https", host: host}) do
    host = to_charlist(host)

    sni =
      case :inet.parse_address(host) do
        {:ok, _ip} -> []
        {:error, _} -> [server_name_indication: host]
      end

    [
      ssl:
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ sni
    ]
  end

  defp ssl(_uri), do: []
end

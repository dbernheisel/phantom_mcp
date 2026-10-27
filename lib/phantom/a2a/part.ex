defmodule Phantom.A2A.Part do
  @moduledoc """
  One piece of content in an A2A message or artifact.

  A part holds exactly one of `text`, `raw` bytes, a `url`, or structured
  `data`, with optional `media_type`, `filename`, and `metadata`.
  """

  import Phantom.Utils, only: [remove_nils: 1]

  defstruct [:text, :raw, :url, :data, :metadata, :filename, :media_type]

  @type t :: %__MODULE__{
          text: String.t() | nil,
          raw: binary() | nil,
          url: String.t() | nil,
          data: term(),
          metadata: map() | nil,
          filename: String.t() | nil,
          media_type: String.t() | nil
        }

  @doc "A text part"
  def text(text, opts \\ []) when is_binary(text), do: struct!(__MODULE__, [text: text] ++ opts)

  @doc "A part of raw bytes, sent base64-encoded"
  def raw(bytes, opts \\ []) when is_binary(bytes), do: struct!(__MODULE__, [raw: bytes] ++ opts)

  @doc "A part that points at a file by URL"
  def url(url, opts \\ []) when is_binary(url), do: struct!(__MODULE__, [url: url] ++ opts)

  @doc "A part of structured JSON data"
  def data(data, opts \\ []), do: struct!(__MODULE__, [data: data] ++ opts)

  @doc false
  def from_json(%{} = json) do
    with {:ok, part} <- content(json) do
      {:ok,
       %{
         part
         | metadata: json["metadata"],
           filename: json["filename"],
           media_type: json["mediaType"]
       }}
    end
  end

  def from_json(_json), do: {:error, "part must be an object"}

  defp content(%{"text" => text}) when is_binary(text), do: {:ok, %__MODULE__{text: text}}
  defp content(%{"url" => url}) when is_binary(url), do: {:ok, %__MODULE__{url: url}}
  defp content(%{"data" => data}), do: {:ok, %__MODULE__{data: data}}

  defp content(%{"raw" => raw}) when is_binary(raw) do
    case Base.decode64(raw) do
      {:ok, bytes} -> {:ok, %__MODULE__{raw: bytes}}
      :error -> {:error, "part raw content must be base64"}
    end
  end

  defp content(_json), do: {:error, "part must have text, raw, url, or data"}

  @doc false
  def to_json(%__MODULE__{} = part) do
    remove_nils(%{
      "text" => part.text,
      "raw" => part.raw && Base.encode64(part.raw),
      "url" => part.url,
      "data" => part.data,
      "metadata" => part.metadata,
      "filename" => part.filename,
      "mediaType" => part.media_type
    })
  end
end

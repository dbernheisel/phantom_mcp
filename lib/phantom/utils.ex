defmodule Phantom.Utils do
  @moduledoc false

  def remove_nils(map) do
    for {k, v} when not is_nil(v) <- map, into: %{}, do: {k, v}
  end

  def encode(%{text: data, mimeType: "application/json"} = result) when is_map(data) do
    put_in(result[:text], JSON.encode!(data))
  end

  def encode(%{text: _data, mimeType: nil} = result) do
    put_in(result[:mimeType], "text/plain")
  end

  def encode(%{blob: blob, mimeType: nil} = result) when is_binary(blob) do
    encode(put_in(result[:mimeType], "application/octet-stream"))
  end

  def encode(%{blob: blob} = result) when is_binary(blob) do
    put_in(result[:blob], Base.encode64(blob))
  end

  def encode(%{data: blob, mimeType: nil} = result) when is_binary(blob) do
    encode(put_in(result[:mimeType], "application/octet-stream"))
  end

  def encode(%{data: blob} = result) when is_binary(blob) do
    put_in(result[:data], Base.encode64(blob))
  end

  def encode(%{content: content} = response), do: Map.put(response, :content, encode(content))
  def encode(result), do: remove_nils(result)

  def completion_response(results) when is_list(results) do
    %{
      completion: %{
        values: Enum.take(List.wrap(results), 100),
        hasMore: length(results) > 100
      }
    }
  end

  def completion_response(%{} = results) do
    %{
      completion:
        remove_nils(%{
          values: Enum.take(List.wrap(results[:values]), 100),
          total: results[:total],
          hasMore: results[:has_more] || false
        })
    }
  end
end

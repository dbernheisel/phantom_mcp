defmodule Phantom.Utils do
  @moduledoc false

  def remove_nils(map) do
    for {k, v} when not is_nil(v) <- map, into: %{}, do: {k, v}
  end
end

defmodule Phantom do
  @external_resource "README.md"

  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC -->")
             |> List.last()
end

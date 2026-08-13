defmodule Phantom.Test.PurgeableSchema do
  @moduledoc """
  A schema module compiled to disk so tests can purge it from the VM and
  exercise the code path where a module named only as a field type has not
  been loaded yet.
  """

  use Phantom.Tool.JSONSchema

  input_schema do
    field :name, :string, required: true
    field :ports, {:array, :integer}
  end
end

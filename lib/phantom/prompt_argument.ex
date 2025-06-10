defmodule Phantom.Prompt.Argument do
  import Phantom.Utils

  defstruct [:name, :description, required: false]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          required: boolean()
        }

  @type json :: %{
          name: String.t(),
          description: String.t(),
          required: boolean()
        }

  @spec build(map() | Keyword.t()) :: t()
  def build(attrs), do: struct!(__MODULE__, attrs)

  @spec to_json(t()) :: json()
  def to_json(%__MODULE__{} = argument) do
    remove_nils(%{
      name: argument.name,
      description: argument.description,
      required: argument.required
    })
  end
end

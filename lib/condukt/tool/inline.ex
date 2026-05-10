defmodule Condukt.Tool.Inline do
  @moduledoc """
  Struct returned by `Condukt.tool/1`.

  Prefer building values through `Condukt.tool/1` instead of constructing this
  struct directly.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          call: (map(), map() -> {:ok, term()} | {:ok, term(), map()} | {:error, term()})
        }

  defstruct [:name, :description, :parameters, :call]
end

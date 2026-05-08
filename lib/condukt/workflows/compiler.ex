defmodule Condukt.Workflows.Compiler do
  @moduledoc """
  Compiles `.exs` workflow files to JSON workflow documents.

  An `.exs` workflow is an Elixir script whose final expression
  evaluates to a map describing the workflow. The preferred authoring
  surface is `Condukt.Workflows.DSL`, which provides macros that build
  that map. Returning a map directly is still supported.

  Atom keys and atom values (other than `nil`, `true`, `false`) are
  normalized to strings; the rest of the data must already match the
  schema.

  Standard Elixir features (`def` inside a `defmodule`, anonymous
  functions, `for`, `if`, comprehensions, `Enum`, etc.) are available
  for compile-time meta-programming. References between steps are
  written as plain `${...}` expression strings: there is no runtime
  introspection of step outputs at compile time.

      # hello.exs
      use Condukt.Workflows.DSL

      workflow "hello" do
        input :name, :string
        cmd :greet, ["echo", "Hello, \#{input(:name)}"]
        output step(:greet, :stdout)
      end
  """

  @doc """
  Reads, evaluates, and normalizes an `.exs` workflow file.

  Returns `{:ok, decoded_map}` where the map is ready to be validated
  against the workflow schema.
  """
  @spec compile(Path.t()) :: {:ok, map()} | {:error, term()}
  def compile(path) when is_binary(path) do
    with {:ok, source} <- read(path) do
      compile_string(source, path)
    end
  end

  @doc """
  Evaluates an `.exs` workflow source string. `path` is used only for
  error reporting.
  """
  @spec compile_string(String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def compile_string(source, path) do
    case eval(source, path) do
      {:ok, value} when is_map(value) -> {:ok, normalize(value)}
      {:ok, value} when is_list(value) -> normalize_keyword(value, path)
      {:ok, _other} -> {:error, {:not_a_workflow, path, :result_must_be_a_map}}
      {:error, _} = err -> err
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp eval(source, path) do
    try do
      {value, _bindings} = Code.eval_string(source, [], file: path)
      {:ok, value}
    rescue
      error -> {:error, {:eval_failed, path, Exception.message(error)}}
    end
  end

  defp normalize_keyword(list, path) do
    if Keyword.keyword?(list) do
      {:ok, list |> Map.new() |> normalize()}
    else
      {:error, {:not_a_workflow, path, :result_must_be_a_map}}
    end
  end

  defp normalize(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string_key(k), normalize(v)} end)
  end

  defp normalize(list) when is_list(list) do
    if Keyword.keyword?(list) and list != [] do
      list |> Map.new() |> normalize()
    else
      Enum.map(list, &normalize/1)
    end
  end

  defp normalize(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp normalize(other), do: other

  defp to_string_key(k) when is_binary(k), do: k
  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
end

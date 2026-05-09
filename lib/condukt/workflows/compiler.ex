defmodule Condukt.Workflows.Compiler do
  @moduledoc """
  Normalizes `.exs` workflow files to workflow documents.

  An `.exs` workflow is an Elixir script whose final expression
  evaluates to a map describing the workflow. This is a low-level
  generation escape hatch. Human-authored workflow files should
  generally use HCL and let `Condukt.Workflows.HCLCompiler` produce the
  same map.

  Atom keys and atom values (other than `nil`, `true`, `false`) are
  normalized to strings; the rest of the data must already match the
  workflow document shape.

  Standard Elixir features (`def` inside a `defmodule`, anonymous
  functions, `for`, `if`, comprehensions, `Enum`, etc.) are available
  for document generation. References between steps are
  written as plain `${...}` expression strings.

      # hello.exs
      %{
        inputs: %{name: %{type: :string}},
        steps: %{greet: %{kind: :cmd, argv: ["echo", "Hello, ${inputs.name}"]}},
        output: "${steps.greet.stdout}"
      }
  """

  @doc """
  Reads, evaluates, and normalizes an `.exs` workflow file.

  Returns `{:ok, decoded_map}` where the map is ready for workflow
  document validation.
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
    {value, _bindings} = Code.eval_string(source, [], file: path)
    {:ok, value}
  rescue
    error -> {:error, {:eval_failed, path, Exception.message(error)}}
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

  defp normalize(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)

  defp normalize(other), do: other

  defp to_string_key(k) when is_binary(k), do: k
  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
end

defmodule Condukt.Workflows.Document do
  @moduledoc """
  Loaded representation of a workflow document.

  A document is the canonical form executed by `Condukt.Workflows`. It
  is produced by loading an HCL workflow or `.exs` workflow generator,
  validating the normalized map, and filling in defaults like `name`
  from the file basename.
  """

  alias Condukt.Workflows.{Compiler, HCLCompiler, Validator}

  @enforce_keys [:name, :steps]
  defstruct [
    :name,
    :path,
    :output,
    :raw,
    inputs: %{},
    runtime: %{},
    steps: %{}
  ]

  @type input_spec :: %{required(String.t()) => term()}
  @type step :: %{required(String.t()) => term()}

  @type t :: %__MODULE__{
          name: String.t(),
          path: nil | Path.t(),
          inputs: %{optional(String.t()) => input_spec()},
          runtime: map(),
          steps: %{optional(String.t()) => step()},
          output: term(),
          raw: map()
        }

  @type load_error ::
          {:read_failed, Path.t(), File.posix()}
          | {:compile_failed, Path.t(), term()}
          | {:unsupported_extension, Path.t()}
          | {:invalid_workflow, term()}

  @doc """
  Loads, normalizes, and validates a workflow document at `path`.

  Accepts `.hcl` and `.exs` paths. Returns `{:ok, %Document{}}` when
  the file parses and matches the workflow document shape. Otherwise
  returns a tagged error suitable for reporting from the CLI.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, load_error()}
  def load(path) when is_binary(path) do
    with {:ok, decoded} <- decode_file(path),
         {:ok, validated} <- validate(decoded) do
      {:ok, build(path, validated)}
    end
  end

  @doc """
  Validates a decoded document map without touching the filesystem.
  Useful when the document is produced in memory.
  """
  @spec from_map(map(), keyword()) :: {:ok, t()} | {:error, load_error()}
  def from_map(decoded, opts \\ []) when is_map(decoded) do
    path = Keyword.get(opts, :path)

    case validate(decoded) do
      {:ok, validated} -> {:ok, build(path, validated)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Validates a user-provided inputs map against the document's declared
  inputs. Inputs without a `default` are required.
  """
  @spec validate_inputs(t(), map()) :: {:ok, map()} | {:error, JSV.ValidationError.t()}
  def validate_inputs(%__MODULE__{inputs: declared}, provided) when is_map(declared) and is_map(provided) do
    schema = inputs_schema(declared)
    root = JSV.build!(schema)
    merged = apply_defaults(declared, provided)

    case JSV.validate(merged, root) do
      {:ok, value} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp decode_file(path) do
    case Path.extname(path) do
      ".hcl" ->
        case HCLCompiler.compile(path) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, {:read_failed, _path, _reason} = reason} -> {:error, reason}
          {:error, reason} -> {:error, {:compile_failed, path, reason}}
        end

      ".exs" ->
        case Compiler.compile(path) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, {:read_failed, _path, _reason} = reason} -> {:error, reason}
          {:error, reason} -> {:error, {:compile_failed, path, reason}}
        end

      _ ->
        {:error, {:unsupported_extension, path}}
    end
  end

  defp validate(decoded) do
    case Validator.validate(decoded) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_workflow, reason}}
    end
  end

  defp build(path, validated) do
    name = Map.get(validated, "name") || basename(path) || "workflow"

    %__MODULE__{
      name: name,
      path: path,
      inputs: Map.get(validated, "inputs", %{}),
      runtime: Map.get(validated, "runtime", %{}),
      steps: Map.fetch!(validated, "steps"),
      output: Map.get(validated, "output"),
      raw: validated
    }
  end

  defp basename(nil), do: nil
  defp basename(path), do: Path.basename(path, Path.extname(path))

  defp inputs_schema(declared) do
    required =
      declared
      |> Enum.reject(fn {_id, spec} -> Map.has_key?(spec, "default") end)
      |> Enum.map(fn {id, _} -> id end)

    %{
      "type" => "object",
      "properties" => declared,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp apply_defaults(declared, provided) do
    Enum.reduce(declared, provided, fn {id, spec}, acc ->
      case Map.has_key?(acc, id) do
        true -> acc
        false -> if Map.has_key?(spec, "default"), do: Map.put(acc, id, spec["default"]), else: acc
      end
    end)
  end
end

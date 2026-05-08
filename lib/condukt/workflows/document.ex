defmodule Condukt.Workflows.Document do
  @moduledoc """
  Loaded representation of a workflow document.

  A document is the canonical form executed by `Condukt.Workflows`. It
  is produced by reading a `.json` file from disk, validating it
  against the published schema (`Condukt.Workflows.Schema`), and
  filling in defaults like `name` from the file basename.

  HCL, YAML, and `.exs` files are decoded to a JSON document upstream
  of validation.
  """

  alias Condukt.Workflows.{Compiler, HCLCompiler, Schema}

  @enforce_keys [:name, :steps]
  defstruct [
    :name,
    :path,
    :output,
    :raw,
    inputs: %{},
    steps: %{}
  ]

  @type input_spec :: %{required(String.t()) => term()}
  @type step :: %{required(String.t()) => term()}

  @type t :: %__MODULE__{
          name: String.t(),
          path: nil | Path.t(),
          inputs: %{optional(String.t()) => input_spec()},
          steps: %{optional(String.t()) => step()},
          output: term(),
          raw: map()
        }

  @type load_error ::
          {:read_failed, Path.t(), File.posix()}
          | {:decode_failed, Path.t(), term()}
          | {:compile_failed, Path.t(), term()}
          | {:unsupported_extension, Path.t()}
          | {:invalid_workflow, JSV.ValidationError.t()}

  @doc """
  Loads, decodes, and validates a workflow document at `path`.

  Accepts `.json`, `.yaml`/`.yml`, `.hcl`, and `.exs` paths. Returns
  `{:ok, %Document{}}` when the file parses, decodes, and matches the
  schema. Otherwise returns a tagged error suitable for reporting
  from the CLI.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, load_error()}
  def load(path) when is_binary(path) do
    with {:ok, decoded} <- decode_file(path),
         {:ok, validated} <- validate(decoded) do
      {:ok, build(path, validated)}
    end
  end

  @doc """
  Validates a decoded document map against the schema without touching
  the filesystem. Useful when the document is produced in memory.
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
      ext when ext in [".json", ""] ->
        with {:ok, source} <- read(path), do: decode_json(path, source)

      ext when ext in [".yaml", ".yml"] ->
        with {:ok, source} <- read(path), do: decode_yaml(path, source)

      ".hcl" ->
        case HCLCompiler.compile(path) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:compile_failed, path, reason}}
        end

      ".exs" ->
        case Compiler.compile(path) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:compile_failed, path, reason}}
        end

      _ ->
        {:error, {:unsupported_extension, path}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp decode_json(path, source) do
    case JSON.decode(source) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:decode_failed, path, :not_an_object}}
      {:error, reason} -> {:error, {:decode_failed, path, reason}}
    end
  end

  defp decode_yaml(path, source) do
    case YamlElixir.read_from_string(source) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:decode_failed, path, :not_an_object}}
      {:error, reason} -> {:error, {:decode_failed, path, reason}}
    end
  end

  defp validate(decoded) do
    case JSV.validate(decoded, Schema.root()) do
      {:ok, value} -> {:ok, value}
      {:error, %JSV.ValidationError{} = err} -> {:error, {:invalid_workflow, err}}
    end
  end

  defp build(path, validated) do
    name = Map.get(validated, "name") || basename(path) || "workflow"

    %__MODULE__{
      name: name,
      path: path,
      inputs: Map.get(validated, "inputs", %{}),
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

defmodule Condukt.Workflows do
  @moduledoc """
  Public facade for Condukt workflows.

  A workflow is a typed JSON document describing a directed acyclic
  graph of steps. The document is the source of truth: it is what the
  engine executes, what `check/1` validates, and what editors and
  agents read and write. The basename of the file is the run name.

  The published JSON Schema lives in this repo at
  `priv/schemas/condukt.workflow.schema.json` and is mirrored at:

      https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json

  HCL, YAML, and `.exs` files are converted to a JSON document at
  load time and arrive here as already-decoded maps via
  `run_document/3`.
  """

  alias Condukt.Workflows.{Compiler, Document, Executor, HCLCompiler}

  @type input :: map()
  @type result :: term()
  @type opts :: keyword()

  @doc """
  Runs a workflow path or an already-loaded workflow document.

  Returns `{:ok, value}` where `value` is the resolved top-level
  `output` expression of the document. Returns `{:error, reason}`
  on read, decode, validation, or execution failure.

  Passing a loaded `Condukt.Workflows.Document` lets library callers
  load or compile a workflow once, then execute it multiple times with
  different inputs or runtime options.
  """
  @spec run(Path.t(), input(), opts()) :: {:ok, result()} | {:error, term()}
  @spec run(Document.t(), input(), opts()) :: {:ok, result()} | {:error, term()}
  def run(path_or_doc, inputs \\ %{}, opts \\ [])

  def run(path, inputs, opts) when is_binary(path) and is_map(inputs) do
    with {:ok, doc} <- Document.load(path) do
      run(doc, inputs, opts)
    end
  end

  def run(%Document{} = doc, inputs, opts) when is_map(inputs) do
    with {:ok, %{output: output}} <- Executor.run(doc, inputs, opts) do
      {:ok, output}
    end
  end

  @doc """
  Loads and validates a workflow file without executing it.
  """
  @spec load(Path.t()) :: {:ok, Document.t()} | {:error, term()}
  def load(path) when is_binary(path), do: Document.load(path)

  @doc """
  Runs a pre-decoded workflow document. The map is validated against
  the schema before execution. Used by the HCL, `.exs`, and YAML
  loaders, which produce documents in memory.
  """
  @spec run_document(map(), input(), opts()) :: {:ok, result()} | {:error, term()}
  def run_document(decoded, inputs \\ %{}, opts \\ []) when is_map(decoded) do
    with {:ok, doc} <- Document.from_map(decoded, Keyword.take(opts, [:path])),
         {:ok, %{output: output}} <- Executor.run(doc, inputs, opts) do
      {:ok, output}
    end
  end

  @doc """
  Validates a workflow file without executing it.

  Returns `:ok` on success, or `{:error, reason}` if the file fails to
  read, decode, compile, or match the schema. Accepts `.json`,
  `.yaml`, `.yml`, `.hcl`, and `.exs` paths.
  """
  @spec check(Path.t()) :: :ok | {:error, term()}
  def check(path) when is_binary(path) do
    case Document.load(path) do
      {:ok, _doc} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Compiles an authored workflow file to its JSON document
  representation. Returns the JSON as a compact string.
  """
  @spec compile(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def compile(path) when is_binary(path) do
    compiler =
      case Path.extname(path) do
        ".hcl" -> HCLCompiler
        ".exs" -> Compiler
        ext -> {:error, {:unsupported_compile_extension, path, ext}}
      end

    case compiler do
      {:error, _} = err ->
        err

      module ->
        with {:ok, decoded} <- module.compile(path) do
          {:ok, JSON.encode!(decoded)}
        end
    end
  end
end

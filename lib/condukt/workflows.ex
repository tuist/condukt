defmodule Condukt.Workflows do
  @moduledoc """
  Public facade for Condukt workflows.

  A workflow is a typed JSON document describing a directed acyclic
  graph of steps. The document is the source of truth: it is what the
  engine executes, what `check/1` validates, and what editors and
  agents read and write. The basename of the file is the run name.

  The published JSON Schema lives in this repo at
  `priv/schemas/condukt.workflow.schema.json` and is mirrored at:

      https://condukt.tuist.dev/schemas/condukt.workflow.schema.json

  YAML and Starlark inputs are converted to a JSON document upstream
  in later slices and arrive here as already-decoded maps via
  `run_document/3`.
  """

  alias Condukt.Workflows.{Document, Executor}

  @type input :: map()
  @type result :: term()
  @type opts :: keyword()

  @doc """
  Runs a workflow file at `path` with the given `inputs`.

  Returns `{:ok, value}` where `value` is the resolved top-level
  `output` expression of the document. Returns `{:error, reason}`
  on read, decode, validation, or execution failure.
  """
  @spec run(Path.t(), input(), opts()) :: {:ok, result()} | {:error, term()}
  def run(path, inputs \\ %{}, opts \\ []) when is_binary(path) and is_map(inputs) do
    with {:ok, doc} <- Document.load(path),
         {:ok, %{output: output}} <- Executor.run(doc, inputs, opts) do
      {:ok, output}
    end
  end

  @doc """
  Runs a pre-decoded workflow document. The map is validated against
  the schema before execution. Used by the Starlark compiler and the
  YAML loader, which both produce documents in memory.
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
  read, decode, or match the schema.
  """
  @spec check(Path.t()) :: :ok | {:error, term()}
  def check(path) when is_binary(path) do
    case Document.load(path) do
      {:ok, _doc} -> :ok
      {:error, _} = err -> err
    end
  end
end

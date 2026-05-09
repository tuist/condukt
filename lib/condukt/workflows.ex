defmodule Condukt.Workflows do
  @moduledoc """
  Public facade for Condukt workflows.

  A workflow is a typed document describing a directed acyclic
  graph of steps. The document is the source of truth: it is what the
  engine executes, what `check/1` validates, and what editors and
  agents read and write. HCL workflows use the `workflow "name"` label
  as the run name. `.exs` workflow maps may set `name`; if they omit it,
  Condukt falls back to the file basename.

  HCL and `.exs` files are normalized to a workflow document at load
  time and arrive here as already-decoded maps via `run_document/3`.
  """

  alias Condukt.Workflows.{Document, Executor}

  @type input :: map()
  @type result :: term()
  @type opts :: keyword()

  @doc """
  Runs a workflow path or an already-loaded workflow document.

  Returns `{:ok, value}` where `value` is the resolved top-level
  `output` expression of the document. Returns `{:error, reason}`
  on read, decode, validation, or execution failure.

  Passing a loaded `Condukt.Workflows.Document` lets library callers
  load a workflow once, then execute it multiple times with different
  inputs or runtime options.
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
  the workflow document shape before execution. Used by callers that
  produce documents in memory.
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
  read, normalize, or match the workflow document shape. Accepts
  `.hcl` and `.exs` paths.
  """
  @spec check(Path.t()) :: :ok | {:error, term()}
  def check(path) when is_binary(path) do
    case Document.load(path) do
      {:ok, _doc} -> :ok
      {:error, _} = err -> err
    end
  end
end

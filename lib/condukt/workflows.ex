defmodule Condukt.Workflows do
  @moduledoc """
  Public facade for Condukt workflows.

  A workflow is a typed document describing a directed acyclic
  graph of steps. The document is the source of truth: it is what the
  engine executes, what `check/1` validates, and what editors and
  agents read and write. HCL workflows use the `workflow "name"` label
  as the run name. `.exs` workflow maps may set `name`; if they omit it,
  Condukt falls back to the file basename.

  HCL source strings, HCL files, and `.exs` files are normalized to a
  workflow document before execution.
  """

  alias Condukt.Workflows.{Document, Executor, HCLCompiler}

  @doc """
  Runs an HCL workflow source string or an already-loaded workflow
  document.

  Returns `{:ok, value}` where `value` is the resolved top-level
  `output` expression of the document. Returns `{:error, reason}`
  on normalization, validation, or execution failure.

  When passing a string, the string is interpreted as HCL source
  content, not as a file path. Callers that keep HCL workflows on disk
  should read the file first and pass the content to this function.
  """
  def run(source_or_doc, inputs \\ %{}, opts \\ [])

  def run(source, inputs, opts) when is_binary(source) and is_map(inputs) do
    load_opts = Keyword.take(opts, [:path])
    runtime_opts = Keyword.delete(opts, :path)

    with {:ok, doc} <- document_from_source(source, load_opts) do
      run(doc, inputs, runtime_opts)
    end
  end

  def run(%Document{} = doc, inputs, opts) when is_map(inputs) do
    with {:ok, %{output: output}} <- Executor.run(doc, inputs, opts) do
      {:ok, output}
    end
  end

  @doc """
  Loads and validates a workflow file without executing it.

  Use this when you explicitly need a reusable
  `Condukt.Workflows.Document`, or when loading `.exs` workflow
  generator files. HCL callers that only need to execute a workflow can
  read the file content and pass it directly to `run/3`.
  """
  def load(path) when is_binary(path), do: Document.load(path)

  @doc """
  Runs a pre-decoded workflow document. The map is validated against
  the workflow document shape before execution. Used by callers that
  produce documents in memory.
  """
  def run_document(decoded, inputs \\ %{}, opts \\ []) when is_map(decoded) do
    with {:ok, doc} <- Document.from_map(decoded, Keyword.take(opts, [:path])),
         {:ok, %{output: output}} <- Executor.run(doc, inputs, opts) do
      {:ok, output}
    end
  end

  defp document_from_source(source, opts) do
    path = Keyword.get(opts, :path)
    diagnostic_path = path || "<hcl>"

    case HCLCompiler.compile_string(source, diagnostic_path) do
      {:ok, decoded} -> Document.from_map(decoded, path: path)
      {:error, reason} -> {:error, {:compile_failed, diagnostic_path, reason}}
    end
  end

  @doc """
  Validates a workflow file without executing it.

  Returns `:ok` on success, or `{:error, reason}` if the file fails to
  read, normalize, or match the workflow document shape. Accepts
  `.hcl` and `.exs` paths.
  """
  def check(path) when is_binary(path) do
    case Document.load(path) do
      {:ok, _doc} -> :ok
      {:error, _} = err -> err
    end
  end
end

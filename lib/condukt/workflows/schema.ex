defmodule Condukt.Workflows.Schema do
  @moduledoc """
  Loader for the canonical Condukt workflow JSON Schema.

  The schema lives at `priv/schemas/condukt.workflow.schema.json`.
  Workflow files reference it via `$schema` against the raw URL on
  GitHub, which is what `url/0` returns.

  At compile time the schema is read and built into a `JSV` root so that
  validation does not pay parse cost on every run.
  """

  @schema_path Path.expand("../../../priv/schemas/condukt.workflow.schema.json", __DIR__)
  @external_resource @schema_path

  @raw File.read!(@schema_path)
  @schema JSON.decode!(@raw)
  @root JSV.build!(@schema)

  @doc "Returns the schema as a decoded map."
  @spec schema() :: map()
  def schema, do: @schema

  @doc "Returns the raw schema JSON as it appears on disk."
  @spec raw() :: binary()
  def raw, do: @raw

  @doc "Returns the prebuilt JSV root used for validation."
  @spec root() :: JSV.Root.t()
  def root, do: @root

  @doc """
  Public canonical URL of the schema. Workflow files reference this via
  `$schema` so editors and validators can discover it.
  """
  @spec url() :: String.t()
  def url,
    do: "https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json"
end

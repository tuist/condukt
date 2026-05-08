defmodule Condukt.Workflows.ToolRegistry do
  @moduledoc """
  Resolves the `id` field of a `tool` workflow step to a tool module
  (or inline tool spec) suitable for `Condukt.Tool.execute/3`.

  Built-in tools are registered under their declared `name/0`:

  - `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Bash`

  Callers can extend the registry by passing a `tools: %{id => spec}`
  option to `Condukt.Workflows.run/3`. Custom entries override the
  built-ins.
  """

  @builtin %{
    "Read" => Condukt.Tools.Read,
    "Write" => Condukt.Tools.Write,
    "Edit" => Condukt.Tools.Edit,
    "Glob" => Condukt.Tools.Glob,
    "Grep" => Condukt.Tools.Grep,
    "Bash" => Condukt.Tools.Bash
  }

  @type tool_spec :: module() | {module(), keyword()}

  @doc """
  Returns the built-in tool registry as a map of id to tool spec.
  """
  @spec builtin() :: %{String.t() => tool_spec()}
  def builtin, do: @builtin

  @doc """
  Resolves `id` against the merged registry. `extra` overrides the
  built-ins.
  """
  @spec resolve(String.t(), %{String.t() => tool_spec()}) ::
          {:ok, tool_spec()} | {:error, {:unknown_tool, String.t()}}
  def resolve(id, extra \\ %{}) when is_binary(id) do
    merged = Map.merge(@builtin, extra)

    case Map.fetch(merged, id) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_tool, id}}
    end
  end
end

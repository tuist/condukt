defmodule Condukt.Engine.CLI do
  @moduledoc """
  Command-line entrypoint for the standalone Condukt engine.

  The engine exposes workflow commands without requiring Elixir or Mix
  on the target machine.
  """

  alias Condukt.Workflows

  @doc """
  Runs the engine command line and returns the process exit status.
  """
  def main(args) when is_list(args) do
    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch([]), do: {:ok, usage()}
  defp dispatch(["help"]), do: {:ok, usage()}
  defp dispatch(["--help"]), do: {:ok, usage()}
  defp dispatch(["-h"]), do: {:ok, usage()}
  defp dispatch(["version"]), do: {:ok, version()}
  defp dispatch(["--version"]), do: {:ok, version()}
  defp dispatch(["run" | args]), do: run_workflow(args)
  defp dispatch(["check" | args]), do: check_workflow(args)
  defp dispatch([unknown | _args]), do: {:error, "Unknown command: #{unknown}\n\n#{usage()}"}

  defp run_workflow(args) do
    with {:ok, opts, [path]} <- parse_options(args, input: :string),
         {:ok, inputs} <- decode_input(opts[:input]),
         {:ok, result} <- Workflows.run(path, inputs) do
      {:ok, format_result(result)}
    else
      {:ok, _opts, []} -> {:error, "Expected a workflow path"}
      {:ok, _opts, rest} -> {:error, "Expected exactly one path, got: #{Enum.join(rest, " ")}"}
      {:error, reason} -> {:error, "Workflow run failed: #{inspect(reason)}"}
    end
  end

  defp check_workflow(args) do
    case parse_options(args, []) do
      {:ok, _opts, [path]} ->
        case Workflows.check(path) do
          :ok -> {:ok, "ok: #{path}"}
          {:error, reason} -> {:error, "check failed: #{inspect(reason)}"}
        end

      {:ok, _opts, []} ->
        {:error, "Expected a workflow path"}

      {:ok, _opts, rest} ->
        {:error, "Expected exactly one path, got: #{Enum.join(rest, " ")}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_options(args, switches) do
    case OptionParser.parse(args, strict: switches) do
      {opts, rest, []} -> {:ok, opts, rest}
      {_opts, _rest, invalid} -> {:error, "Invalid options: #{inspect(invalid)}"}
    end
  end

  defp decode_input(nil), do: {:ok, %{}}

  defp decode_input(encoded) do
    case JSON.decode(encoded) do
      {:ok, input} when is_map(input) -> {:ok, input}
      {:ok, _other} -> {:error, "--input must decode to a JSON object"}
      {:error, reason} -> {:error, {:invalid_input_json, reason}}
    end
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(nil), do: ""
  defp format_result(other), do: JSON.encode!(other)

  defp print_result({:ok, ""}), do: 0

  defp print_result({:ok, output}) do
    IO.puts(output)
    0
  end

  defp print_result({:error, message}) do
    IO.puts(:stderr, message)
    1
  end

  defp version do
    :condukt
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp usage do
    """
    Condukt engine #{version()}

    Usage:
      condukt version
      condukt run PATH [--input JSON]    Run a workflow file (.hcl/.json/.yaml/.yml/.exs)
      condukt check PATH                 Validate a workflow against the schema

    Workflow JSON Schema:
      https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json
    """
    |> String.trim()
  end
end

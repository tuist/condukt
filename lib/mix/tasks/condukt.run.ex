defmodule Mix.Tasks.Condukt.Run do
  @moduledoc """
  Runs a Condukt workflow file.

      mix condukt.run path/to/workflow.json [--input JSON]

  The file must be a JSON document conforming to
  `condukt.workflow.schema.json`. YAML and Starlark inputs are
  supported in later slices.
  """

  use Mix.Task

  @shortdoc "Runs a Condukt workflow file"

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [input: :string])

    case args do
      [path] ->
        with {:ok, inputs} <- decode_inputs(opts[:input]),
             {:ok, result} <- Condukt.Workflows.run(path, inputs) do
          IO.puts(format_result(result))
          :ok
        else
          {:error, reason} ->
            Mix.shell().error("workflow run failed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      [] ->
        Mix.shell().error("Usage: mix condukt.run PATH [--input JSON]")
        exit({:shutdown, 1})

      _ ->
        Mix.shell().error("expected exactly one workflow path")
        exit({:shutdown, 1})
    end
  end

  defp decode_inputs(nil), do: {:ok, %{}}

  defp decode_inputs(json) do
    case JSON.decode(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _other} -> {:error, "--input must decode to a JSON object"}
      {:error, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(nil), do: ""
  defp format_result(other), do: JSON.encode!(other)
end

defmodule Mix.Tasks.Condukt.Check do
  @shortdoc "Validates a Condukt workflow file"

  @moduledoc """
  Validates a Condukt workflow file without executing it.

      mix condukt.check path/to/workflow.hcl

  Validates the workflow and reports any problems. Exits with status 1
  when validation fails.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: []) do
      {_opts, [path], _} ->
        validate(path)

      _ ->
        Mix.shell().error("Usage: mix condukt.check PATH")
        exit({:shutdown, 1})
    end
  end

  defp validate(path) do
    case Condukt.Workflows.check(path) do
      :ok ->
        Mix.shell().info("ok: #{path}")

      {:error, reason} ->
        Mix.shell().error("check failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end

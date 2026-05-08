defmodule Mix.Tasks.Condukt.Compile do
  @moduledoc """
  Compiles a Starlark `.star` workflow file to its JSON document
  representation, printing the result to stdout.

      mix condukt.compile path/to/workflow.star
  """

  use Mix.Task

  @shortdoc "Compiles a Starlark workflow file to JSON"

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: []) do
      {_opts, [path], _} ->
        case Condukt.Workflows.compile(path) do
          {:ok, json} ->
            IO.puts(json)
            :ok

          {:error, reason} ->
            Mix.shell().error("compile failed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error("Usage: mix condukt.compile PATH")
        exit({:shutdown, 1})
    end
  end
end

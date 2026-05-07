defmodule Condukt.Workflows.Runtime.Worker do
  @moduledoc """
  Runtime worker responsible for invoking one materialized workflow.
  """

  use GenServer

  alias Condukt.Workflows.Workflow

  @default_timeout 300_000

  @doc false
  def start_link(opts) do
    workflow = Keyword.fetch!(opts, :workflow)
    GenServer.start_link(__MODULE__, opts, name: via(workflow.name))
  end

  @doc false
  def invoke(name, input, timeout \\ @default_timeout) when is_binary(name) and is_map(input) do
    case Registry.lookup(Condukt.Workflows.Registry, name) do
      [{pid, _value}] -> GenServer.call(pid, {:invoke, input}, timeout)
      [] -> {:error, :not_found}
    end
  end

  @doc false
  def run_once(%Workflow{} = workflow, input) when is_map(input) do
    span(workflow, fn -> start_and_run(workflow, input) end)
  end

  @impl true
  def init(opts) do
    {:ok, %{workflow: Keyword.fetch!(opts, :workflow)}}
  end

  @impl true
  def handle_call({:invoke, input}, _from, state) do
    {:reply, run_once(state.workflow, input), state}
  end

  defp start_and_run(workflow, input) do
    with :ok <- validate_input(input, workflow.inputs_schema),
         {:ok, session_opts} <- Workflow.to_session_opts(workflow) do
      Condukt.run(prompt(workflow, input), session_opts)
    end
  end

  defp validate_input(_input, nil), do: :ok
  defp validate_input(_input, %{} = schema) when map_size(schema) == 0, do: :ok

  defp validate_input(input, schema) when is_map(schema) do
    case JSV.build(schema) do
      {:ok, root} ->
        case JSV.validate(input, root) do
          {:ok, _validated} -> :ok
          {:error, error} -> {:error, {:invalid_input, error}}
        end

      {:error, error} ->
        {:error, {:invalid_input_schema, error}}
    end
  end

  defp prompt(%Workflow{name: name}, input) when map_size(input) == 0 do
    "Run workflow #{name}."
  end

  defp prompt(%Workflow{name: name}, input) do
    "Run workflow #{name} with these arguments:\n\n```json\n#{JSON.encode!(input)}\n```"
  end

  defp via(name), do: {:via, Registry, {Condukt.Workflows.Registry, name}}

  defp span(%Workflow{} = workflow, fun) do
    metadata = %{workflow: workflow.name, source_path: workflow.source_path}
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:condukt, :workflow, :run, :start],
      %{system_time: System.system_time()},
      metadata
    )

    result = fun.()

    :telemetry.execute(
      [:condukt, :workflow, :run, :stop],
      %{duration: System.monotonic_time() - start_time},
      metadata
    )

    result
  end
end

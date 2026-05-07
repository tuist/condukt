defmodule Condukt.Operation do
  @moduledoc """
  Typed, named entrypoints on an agent module.

  An operation declares an input schema, an output schema, and a block of
  instructions. The macro generates a function on the agent module that
  validates the input, runs a transient agent session forced to produce a
  structured result, validates the output, and returns it.

  ## Declaring

      defmodule MyApp.ReviewAgent do
        use Condukt

        @impl true
        def tools, do: [Condukt.Tools.Read]

        operation :review_pr,
          input: %{
            type: "object",
            properties: %{
              repo: %{type: "string"},
              pr_number: %{type: "integer"}
            },
            required: ["repo", "pr_number"]
          },
          output: %{
            type: "object",
            properties: %{
              verdict: %{type: "string", enum: ["approve", "request_changes", "comment"]},
              summary: %{type: "string"}
            },
            required: ["verdict", "summary"]
          },
          instructions: \"""
          Read the PR, decide a verdict, and write a summary.
          \"""
      end

  ## Calling

      {:ok, %{verdict: "approve", summary: _}} =
        MyApp.ReviewAgent.review_pr(%{repo: "tuist/condukt", pr_number: 1})

  Each call spins up a transient `Condukt.Session`, runs the agent loop with
  the agent's tools plus a synthetic `submit_result` tool, captures the
  structured result, and tears the session down. No history is kept across
  calls.

  Schemas must be JSON Schema maps. Atom keys are accepted in both schemas
  and call-site arguments — they are normalized internally.
  """

  alias Condukt.Operation.SubmitTool
  alias Condukt.Telemetry

  defstruct [:name, :input_schema, :output_schema, :instructions]

  @doc false
  defmacro operation(name, opts) do
    input_ast = Keyword.fetch!(opts, :input)
    output_ast = Keyword.fetch!(opts, :output)
    instructions_ast = Keyword.fetch!(opts, :instructions)

    quote do
      @condukt_operations {unquote(name), unquote(input_ast), unquote(output_ast), unquote(instructions_ast)}

      def unquote(name)(args, run_opts \\ []) do
        Condukt.Operation.run(__MODULE__, unquote(name), args, run_opts)
      end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    ops = Module.get_attribute(env.module, :condukt_operations) || []

    ops_map =
      Map.new(ops, fn {name, input, output, instructions} ->
        {name,
         %__MODULE__{
           name: name,
           input_schema: input,
           output_schema: output,
           instructions: instructions
         }}
      end)

    quote do
      @doc false
      def __operations__, do: unquote(Macro.escape(ops_map))

      @doc false
      def __operation__(name), do: Map.fetch(__operations__(), name)
    end
  end

  @doc """
  Runs an operation declared on `agent_module`.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  Failure reasons:

  - `{:invalid_input, %JSV.ValidationError{}}` — args did not match the input schema
  - `{:invalid_output, %JSV.ValidationError{}}` — model output did not match the output schema
  - `:no_result_submitted` — the agent finished without calling `submit_result`
  - `{:unknown_operation, name}` — no operation by that name on the module
  - any error returned by the underlying `Condukt.Session.run/3`
  """
  def run(agent_module, name, args, opts \\ []) do
    Telemetry.span(:operation, %{agent: agent_module, operation: name}, fn ->
      with {:ok, operation} <- fetch_operation(agent_module, name),
           {:ok, normalized} <- normalize(args),
           :ok <- validate_input(operation, normalized) do
        execute(agent_module, operation, normalized, opts)
      end
    end)
  end

  defp fetch_operation(agent_module, name) do
    case agent_module.__operation__(name) do
      {:ok, operation} -> {:ok, operation}
      :error -> {:error, {:unknown_operation, name}}
    end
  end

  defp normalize(args) when is_map(args) do
    {:ok, stringify_keys(args)}
  end

  defp normalize(_args) do
    {:error, {:invalid_input, :args_must_be_a_map}}
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string_key(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k) when is_binary(k), do: k

  defp validate_input(%__MODULE__{input_schema: schema}, args) do
    case build_root(schema) do
      {:ok, root} ->
        case JSV.validate(args, root) do
          {:ok, _validated} -> :ok
          {:error, error} -> {:error, {:invalid_input, error}}
        end

      {:error, error} ->
        {:error, {:invalid_input_schema, error}}
    end
  end

  defp validate_output(%__MODULE__{output_schema: schema}, data) do
    case build_root(schema) do
      {:ok, root} ->
        case JSV.validate(data, root) do
          {:ok, validated} -> {:ok, validated}
          {:error, error} -> {:error, {:invalid_output, error}}
        end

      {:error, error} ->
        {:error, {:invalid_output_schema, error}}
    end
  end

  defp build_root(schema), do: JSV.build(schema)

  defp execute(agent_module, operation, args, opts) do
    ref = make_ref()
    parent = self()

    submit_tool = {SubmitTool, schema: operation.output_schema, reply_to: parent, ref: ref}
    base_prompt = base_system_prompt(agent_module)

    session_opts =
      [
        tools: agent_module.tools() ++ [submit_tool],
        system_prompt: compose_system_prompt(base_prompt, operation),
        load_project_instructions: false
      ]
      |> maybe_put(:api_key, opts[:api_key])
      |> maybe_put(:base_url, opts[:base_url])
      |> maybe_put(:model, opts[:model])

    Condukt.Session.with_transient(agent_module, session_opts, fn pid ->
      run_session(pid, operation, args, opts, ref)
    end)
  end

  defp run_session(pid, operation, args, opts, ref) do
    prompt = encode_prompt(args)
    run_opts = Keyword.take(opts, [:timeout, :max_turns])

    case Condukt.Session.run(pid, prompt, run_opts) do
      {:ok, _text} ->
        await_submission(operation, ref)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_submission(operation, ref) do
    receive do
      {^ref, :operation_submit, submitted} ->
        with {:ok, validated} <- validate_output(operation, submitted) do
          {:ok, atomize_top_level(validated, operation.output_schema)}
        end
    after
      0 -> {:error, :no_result_submitted}
    end
  end

  defp base_system_prompt(agent_module) do
    if function_exported?(agent_module, :system_prompt, 0) do
      agent_module.system_prompt() || ""
    else
      ""
    end
  end

  defp compose_system_prompt(base, operation) do
    pieces =
      [
        base,
        operation.instructions,
        "When you have your final answer, call the `submit_result` tool. Call it exactly once, then stop."
      ]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.join(pieces, "\n\n")
  end

  defp encode_prompt(args) do
    "Run the operation with these arguments:\n\n```json\n#{JSON.encode!(args)}\n```"
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp atomize_top_level(map, output_schema) when is_map(map) do
    properties = Map.get(output_schema, :properties) || Map.get(output_schema, "properties") || %{}

    if properties != %{} and Enum.all?(properties, fn {k, _} -> is_atom(k) end) do
      name_map = Map.new(properties, fn {atom_key, _} -> {Atom.to_string(atom_key), atom_key} end)
      Map.new(map, &remap_key(&1, name_map))
    else
      map
    end
  end

  defp atomize_top_level(other, _output_schema), do: other

  defp remap_key({k, v}, name_map) when is_binary(k) do
    case Map.fetch(name_map, k) do
      {:ok, atom_key} -> {atom_key, v}
      :error -> {k, v}
    end
  end

  defp remap_key(kv, _name_map), do: kv
end

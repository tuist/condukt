defmodule Condukt.Workflows.Executor do
  @moduledoc """
  Executes a validated workflow document.

  The executor topologically sorts the step DAG using each step's
  declared `needs:` plus the step ids referenced by `${...}`
  expressions inside any of its fields. Each step is then run in
  turn:

  1. Skip the step if any of its dependencies were skipped.
  2. Evaluate `when:`. If it is false, mark the step as skipped.
  3. Interpolate the step's fields against the current context.
  4. Dispatch on `kind` to the matching handler (`cmd`, `http`,
     `map`).
  5. Record the step's output in the context.

  After all steps have run, the top-level `output` expression is
  resolved and returned.
  """

  alias Condukt.Sandbox
  alias Condukt.Workflows.{Document, Expr, ToolRegistry}

  def run(%Document{} = doc, inputs \\ %{}, opts \\ []) when is_map(inputs) do
    with {:ok, normalized_inputs} <- Document.validate_inputs(doc, inputs),
         {:ok, order} <- topological_sort(doc.steps),
         {:ok, runtime_opts, owned_sandbox} <- prepare_runtime(doc, opts) do
      result = execute(order, doc, normalized_inputs, runtime_opts)
      cleanup_runtime(owned_sandbox)
      result
    end
  end

  defp prepare_runtime(%Document{runtime: runtime}, opts) do
    runtime_opts =
      []
      |> put_runtime(:model, Map.get(runtime, "model"))
      |> put_runtime(:cwd, Map.get(runtime, "cwd"))
      |> put_runtime(:sandbox, Map.get(runtime, "sandbox"))

    opts = Keyword.merge(runtime_opts, opts)

    case Keyword.fetch(opts, :sandbox) do
      :error ->
        {:ok, opts, nil}

      {:ok, nil} ->
        {:ok, opts, nil}

      {:ok, %Sandbox{} = sandbox} ->
        {:ok, Keyword.put(opts, :sandbox, sandbox), nil}

      {:ok, sandbox_spec} ->
        with {:ok, sandbox} <- resolve_sandbox(sandbox_spec, opts) do
          {:ok, Keyword.put(opts, :sandbox, sandbox), sandbox}
        end
    end
  end

  defp put_runtime(opts, _key, nil), do: opts
  defp put_runtime(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_sandbox("local", opts) do
    Sandbox.resolve({Condukt.Sandbox.Local, sandbox_init_opts(opts)})
  end

  defp resolve_sandbox("virtual", opts) do
    Sandbox.resolve({Condukt.Sandbox.Virtual, sandbox_init_opts(opts)})
  end

  defp resolve_sandbox(spec, _opts), do: Sandbox.resolve(spec)

  defp sandbox_init_opts(opts) do
    case Keyword.get(opts, :cwd) do
      nil -> []
      cwd -> [cwd: cwd]
    end
  end

  defp cleanup_runtime(nil), do: :ok
  defp cleanup_runtime(%Sandbox{} = sandbox), do: Sandbox.shutdown(sandbox)

  ## Topological sort.

  defp topological_sort(steps) do
    deps_map =
      Map.new(steps, fn {id, step} ->
        explicit = Map.get(step, "needs", [])
        inferred = Expr.references(step)
        {id, MapSet.new(explicit ++ inferred)}
      end)

    case validate_known_deps(deps_map, MapSet.new(Map.keys(steps))) do
      :ok -> kahn(deps_map)
      {:error, _} = err -> err
    end
  end

  defp validate_known_deps(deps_map, known) do
    deps_map
    |> Enum.flat_map(fn {id, deps} ->
      for dep <- deps, not MapSet.member?(known, dep), do: {id, dep}
    end)
    |> case do
      [] -> :ok
      [{id, dep} | _] -> {:error, {:unknown_dependency, id, dep}}
    end
  end

  defp kahn(deps_map) do
    incoming = Map.new(deps_map, fn {id, deps} -> {id, MapSet.size(deps)} end)
    ready = for {id, 0} <- incoming, do: id
    do_kahn(ready, incoming, deps_map, [])
  end

  defp do_kahn([], incoming, _deps_map, order) do
    case for {id, count} <- incoming, count > 0, do: id do
      [] -> {:ok, Enum.reverse(order)}
      cycles -> {:error, {:cycle, Enum.sort(cycles)}}
    end
  end

  defp do_kahn([id | rest], incoming, deps_map, order) do
    {new_ready, new_incoming} =
      Enum.reduce(deps_map, {rest, Map.put(incoming, id, 0)}, fn {dep_id, deps}, {ready_acc, incoming_acc} ->
        release_dependent(dep_id, deps, id, ready_acc, incoming_acc)
      end)

    do_kahn(new_ready, new_incoming, deps_map, [id | order])
  end

  defp release_dependent(dep_id, deps, id, ready, incoming) do
    if MapSet.member?(deps, id) and dep_id != id do
      decrement_incoming(dep_id, ready, incoming)
    else
      {ready, incoming}
    end
  end

  defp decrement_incoming(dep_id, ready, incoming) do
    new_count = Map.fetch!(incoming, dep_id) - 1
    ready = if new_count == 0, do: ready ++ [dep_id], else: ready
    {ready, Map.put(incoming, dep_id, new_count)}
  end

  ## Execution.

  defp execute(order, doc, inputs, opts) do
    state = %{
      doc: doc,
      inputs: inputs,
      steps: %{},
      skipped: MapSet.new(),
      opts: opts,
      bindings: %{}
    }

    case Enum.reduce_while(order, {:ok, state}, &execute_step/2) do
      {:ok, final} -> finalize(final)
      {:error, _} = err -> err
    end
  end

  defp execute_step(step_id, {:ok, state}) do
    step = Map.fetch!(state.doc.steps, step_id)

    case run_step(step_id, step, state) do
      {:ok, new_state} -> {:cont, {:ok, new_state}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp run_step(step_id, step, state) do
    deps = Map.get(step, "needs", []) ++ Expr.references(step)

    if Enum.any?(deps, &MapSet.member?(state.skipped, &1)) do
      {:ok, mark_skipped(state, step_id)}
    else
      case evaluate_when(step, state) do
        {:ok, true} -> dispatch(step_id, step, state)
        {:ok, false} -> {:ok, mark_skipped(state, step_id)}
        {:error, reason} -> {:error, {:when_failed, step_id, reason}}
      end
    end
  end

  defp mark_skipped(state, step_id) do
    %{
      state
      | skipped: MapSet.put(state.skipped, step_id),
        steps: Map.put(state.steps, step_id, nil)
    }
  end

  defp evaluate_when(step, state) do
    case Map.get(step, "when") do
      nil ->
        {:ok, true}

      expr when is_binary(expr) ->
        case Expr.interpolate(expr, context(state)) do
          {:ok, true} -> {:ok, true}
          {:ok, false} -> {:ok, false}
          {:ok, other} -> {:error, {:when_not_boolean, other}}
          {:error, _} = err -> err
        end
    end
  end

  defp context(state) do
    %{inputs: state.inputs, steps: state.steps, bindings: state.bindings}
  end

  defp dispatch(step_id, step, state) do
    case Map.fetch!(step, "kind") do
      "cmd" -> run_cmd(step_id, step, state)
      "http" -> run_http(step_id, step, state)
      "map" -> run_map(step_id, step, state)
      "tool" -> run_tool(step_id, step, state)
      "agent" -> run_agent(step_id, step, state)
    end
  end

  defp record(state, step_id, output) do
    {:ok, %{state | steps: Map.put(state.steps, step_id, output)}}
  end

  ## cmd

  defp run_cmd(step_id, step, state) do
    fields = Map.take(step, ["argv", "cwd", "env"])

    case interpolate(fields, state) do
      {:ok, %{"argv" => [program | args]} = resolved} when is_binary(program) ->
        cwd = Map.get(resolved, "cwd") || Keyword.get(state.opts, :cwd)
        env = normalize_env(Map.get(resolved, "env"))

        case execute_cmd(program, args, cwd, env, state.opts) do
          {:ok, output, exit_code} ->
            record(state, step_id, %{
              "ok" => exit_code == 0,
              "stdout" => output,
              "exit_code" => exit_code
            })

          {:error, reason} ->
            {:error, {:cmd_failed, step_id, reason}}
        end

      {:ok, _} ->
        {:error, {:invalid_argv, step_id}}

      {:error, reason} ->
        {:error, {:interpolate_failed, step_id, reason}}
    end
  end

  defp execute_cmd(program, args, cwd, env, opts) do
    case Keyword.get(opts, :sandbox) do
      %Sandbox{} = sandbox ->
        sandbox_exec(sandbox, [program | args], cwd, env)

      _ ->
        host_exec(program, args, cwd || File.cwd!(), env)
    end
  end

  defp sandbox_exec(sandbox, argv, cwd, env) do
    exec_opts =
      []
      |> maybe_put(:cwd, cwd)
      |> maybe_put(:env, env)

    case Sandbox.exec(sandbox, shell_join(argv), exec_opts) do
      {:ok, %{output: output, exit_code: exit_code}} -> {:ok, output, exit_code}
      {:error, reason} -> {:error, reason}
    end
  end

  defp host_exec(program, args, cwd, env) do
    case System.find_executable(program) do
      nil -> {:error, {:not_found, program}}
      _ -> run_host_command(program, args, cwd, env)
    end
  end

  defp run_host_command(program, args, cwd, env) do
    {output, exit_code} = MuonTrap.cmd(program, Enum.map(args, &to_string/1), host_exec_opts(cwd, env))
    {:ok, output, exit_code}
  end

  defp host_exec_opts(cwd, env) do
    [cd: cwd, stderr_to_stdout: true, parallelism: false]
    |> maybe_put(:env, empty_to_nil(env))
  end

  defp empty_to_nil([]), do: nil
  defp empty_to_nil(value), do: value

  defp shell_join(argv), do: Enum.map_join(argv, " ", &shell_escape/1)

  defp shell_escape(value) do
    value = to_string(value)

    if Regex.match?(~r/^[A-Za-z0-9_\/\.\-:=@%+,]+$/, value) do
      value
    else
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end

  defp normalize_env(nil), do: []

  defp normalize_env(map) when is_map(map), do: Enum.map(map, fn {k, v} -> {to_string(k), to_string(v)} end)

  ## http

  defp run_http(step_id, step, state) do
    fields = Map.take(step, ["method", "url", "headers", "body", "expect_status"])

    case interpolate(fields, state) do
      {:ok, resolved} ->
        request_http(step_id, resolved, state)

      {:error, reason} ->
        {:error, {:interpolate_failed, step_id, reason}}
    end
  end

  defp request_http(step_id, resolved, state) do
    req_opts =
      resolved
      |> http_request_opts()
      |> Keyword.merge(Keyword.get(state.opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %Req.Response{} = response} -> handle_http_response(step_id, resolved, response, state)
      {:error, reason} -> {:error, {:http_failed, step_id, reason}}
    end
  end

  defp http_request_opts(resolved) do
    method = resolved |> Map.fetch!("method") |> String.downcase() |> String.to_atom()
    headers = resolved |> Map.get("headers", %{}) |> Enum.map(&header_pair/1)

    [method: method, url: Map.fetch!(resolved, "url"), headers: headers, retry: false]
    |> maybe_put_body(Map.get(resolved, "body"))
  end

  defp handle_http_response(step_id, resolved, response, state) do
    output = %{
      "status" => response.status,
      "headers" => Map.new(response.headers, fn {k, v} -> {k, normalize_header_value(v)} end),
      "body" => response.body
    }

    case enforce_expect_status(resolved, output) do
      :ok -> record(state, step_id, output)
      {:error, reason} -> {:error, {:http_unexpected_status, step_id, reason}}
    end
  end

  defp header_pair({k, v}), do: {to_string(k), to_string(v)}

  defp maybe_put_body(opts, nil), do: opts
  defp maybe_put_body(opts, body) when is_binary(body), do: Keyword.put(opts, :body, body)
  defp maybe_put_body(opts, body), do: Keyword.put(opts, :json, body)

  defp normalize_header_value([single]), do: single
  defp normalize_header_value(list) when is_list(list), do: list
  defp normalize_header_value(other), do: other

  defp enforce_expect_status(resolved, %{"status" => status}) do
    case Map.get(resolved, "expect_status") do
      nil ->
        :ok

      ^status ->
        :ok

      expected when is_integer(expected) ->
        {:error, {:expected, expected, :got, status}}

      expected when is_list(expected) ->
        if status in expected, do: :ok, else: {:error, {:expected, expected, :got, status}}
    end
  end

  ## map

  defp run_map(step_id, step, state) do
    over_expr = Map.fetch!(step, "over")
    binding_name = Map.fetch!(step, "as")
    inner_step = Map.fetch!(step, "do")

    case Expr.interpolate(over_expr, context(state)) do
      {:ok, items} when is_list(items) ->
        run_map_items(items, binding_name, inner_step, state, step_id)

      {:ok, other} ->
        {:error, {:over_must_be_list, step_id, other}}

      {:error, reason} ->
        {:error, {:map_failed, step_id, reason}}
    end
  end

  defp run_map_items(items, binding_name, inner_step, state, step_id) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state, []}, fn {item, index}, {:ok, st, acc} ->
      iter_state = %{st | bindings: Map.put(st.bindings, binding_name, item)}
      anon_id = step_id <> "[" <> Integer.to_string(index) <> "]"

      case run_step(anon_id, inner_step, iter_state) do
        {:ok, after_state} ->
          output = Map.get(after_state.steps, anon_id)
          # Drop the anonymous step from steps and skipped so it does not leak into the public state.
          cleaned = %{
            after_state
            | steps: Map.delete(after_state.steps, anon_id),
              skipped: MapSet.delete(after_state.skipped, anon_id),
              bindings: state.bindings
          }

          {:cont, {:ok, cleaned, [output | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, final_state, results} ->
        record(final_state, step_id, Enum.reverse(results))

      {:error, _} = err ->
        err
    end
  end

  ## tool

  defp run_tool(step_id, step, state) do
    fields = Map.take(step, ["id", "args"])

    case interpolate(fields, state) do
      {:ok, %{"id" => id} = resolved} when is_binary(id) ->
        args = Map.get(resolved, "args", %{})
        extra = Keyword.get(state.opts, :tools, %{})

        with {:ok, spec} <- ToolRegistry.resolve(id, extra),
             tool_ctx = build_tool_context(state),
             {:ok, output} <- Condukt.Tool.execute(spec, args, tool_ctx) do
          record(state, step_id, %{"ok" => true, "output" => output})
        else
          {:error, {:unknown_tool, _} = reason} ->
            {:error, {:tool_failed, step_id, reason}}

          {:error, reason} ->
            record(state, step_id, %{"ok" => false, "error" => format_error(reason)})
        end

      {:ok, _} ->
        {:error, {:invalid_tool_id, step_id}}

      {:error, reason} ->
        {:error, {:interpolate_failed, step_id, reason}}
    end
  end

  defp build_tool_context(state) do
    %{
      sandbox: Keyword.get(state.opts, :sandbox),
      cwd: Keyword.get(state.opts, :cwd, File.cwd!()),
      secrets: Keyword.get(state.opts, :secrets)
    }
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  ## agent

  defp run_agent(step_id, step, state) do
    fields = Map.take(step, ["model", "input", "system", "tools", "output_schema"])

    case interpolate(fields, state) do
      {:ok, %{"input" => input} = resolved} ->
        run_agent_prompt(step_id, stringify_input(input), resolved, state)

      {:ok, _} ->
        {:error, {:invalid_agent_step, step_id}}

      {:error, reason} ->
        {:error, {:interpolate_failed, step_id, reason}}
    end
  end

  defp run_agent_prompt(step_id, prompt, resolved, state) do
    with {:ok, run_opts} <- agent_run_opts(resolved, state),
         {:ok, output} <- Condukt.run(prompt, run_opts) do
      record(state, step_id, %{"ok" => true, "output" => output})
    else
      {:error, reason} -> {:error, {:agent_failed, step_id, reason}}
    end
  end

  defp agent_run_opts(resolved, state) do
    extra = Keyword.get(state.opts, :tools, %{})

    with {:ok, model} <- agent_model(resolved, state),
         {:ok, tool_specs} <- resolve_tool_specs(Map.get(resolved, "tools", []), extra) do
      opts =
        [model: model, tools: tool_specs]
        |> maybe_put(:system_prompt, Map.get(resolved, "system"))
        |> maybe_put(:output, Map.get(resolved, "output_schema"))
        |> maybe_put(:sandbox, Keyword.get(state.opts, :sandbox))
        |> maybe_put(:cwd, Keyword.get(state.opts, :cwd))
        |> maybe_put(:secrets, Keyword.get(state.opts, :secrets))
        |> Keyword.merge(Keyword.get(state.opts, :agent_options, []))

      {:ok, opts}
    end
  end

  defp agent_model(resolved, state) do
    model =
      Map.get(resolved, "model") ||
        Keyword.get(state.opts, :model) ||
        Keyword.get(Keyword.get(state.opts, :agent_options, []), :model)

    case model do
      nil -> {:error, :missing_agent_model}
      model -> {:ok, model}
    end
  end

  defp resolve_tool_specs(ids, extra) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case ToolRegistry.resolve(id, extra) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      err -> err
    end
  end

  defp stringify_input(value) when is_binary(value), do: value
  defp stringify_input(value), do: JSON.encode!(value)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  ## Helpers.

  defp interpolate(value, state), do: Expr.interpolate_value(value, context(state))

  defp finalize(state) do
    case state.doc.output do
      nil ->
        {:ok, build_result(nil, state)}

      output ->
        case Expr.interpolate_value(output, context(state)) do
          {:ok, resolved} -> {:ok, build_result(resolved, state)}
          {:error, _} = err -> err
        end
    end
  end

  defp build_result(output, state) do
    %{output: output, steps: state.steps, skipped: MapSet.to_list(state.skipped)}
  end
end

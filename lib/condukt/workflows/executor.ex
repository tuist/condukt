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

  alias Condukt.Workflows.{Document, Expr}

  @type state :: %{
          doc: Document.t(),
          inputs: map(),
          steps: map(),
          skipped: MapSet.t(),
          opts: keyword(),
          bindings: map()
        }

  @type result :: %{
          output: term(),
          steps: map(),
          skipped: [String.t()]
        }

  @spec run(Document.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(%Document{} = doc, inputs \\ %{}, opts \\ []) when is_map(inputs) do
    with {:ok, normalized_inputs} <- Document.validate_inputs(doc, inputs),
         {:ok, order} <- topological_sort(doc.steps) do
      execute(order, doc, normalized_inputs, opts)
    end
  end

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
      Enum.reduce(deps_map, {rest, Map.put(incoming, id, 0)}, fn {dep_id, deps},
                                                                 {ready_acc, incoming_acc} ->
        if MapSet.member?(deps, id) and dep_id != id do
          new_count = Map.fetch!(incoming_acc, dep_id) - 1
          ready_acc = if new_count == 0, do: ready_acc ++ [dep_id], else: ready_acc
          {ready_acc, Map.put(incoming_acc, dep_id, new_count)}
        else
          {ready_acc, incoming_acc}
        end
      end)

    do_kahn(new_ready, new_incoming, deps_map, [id | order])
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

    case Enum.reduce_while(order, {:ok, state}, fn step_id, {:ok, state} ->
           step = Map.fetch!(state.doc.steps, step_id)

           case run_step(step_id, step, state) do
             {:ok, new_state} -> {:cont, {:ok, new_state}}
             {:error, _} = err -> {:halt, err}
           end
         end) do
      {:ok, final} -> finalize(final)
      {:error, _} = err -> err
    end
  end

  @spec run_step(String.t(), map(), state()) :: {:ok, state()} | {:error, term()}
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
      "agent" -> {:error, {:unsupported_kind, "agent", step_id}}
      "tool" -> {:error, {:unsupported_kind, "tool", step_id}}
    end
  end

  defp record(state, step_id, output) do
    {:ok, %{state | steps: Map.put(state.steps, step_id, output)}}
  end

  ## cmd

  defp run_cmd(step_id, step, state) do
    fields = Map.take(step, ["argv", "cwd", "env"])

    with {:ok, %{"argv" => [program | args]} = resolved} when is_binary(program) <-
           interpolate(fields, state) do
      cwd = Map.get(resolved, "cwd") || Keyword.get(state.opts, :cwd, File.cwd!())
      env = normalize_env(Map.get(resolved, "env"))

      case execute_cmd(program, args, cwd, env) do
        {:ok, output, exit_code} ->
          record(state, step_id, %{
            "ok" => exit_code == 0,
            "stdout" => output,
            "exit_code" => exit_code
          })

        {:error, reason} ->
          {:error, {:cmd_failed, step_id, reason}}
      end
    else
      {:ok, _} -> {:error, {:invalid_argv, step_id}}
      {:error, reason} -> {:error, {:interpolate_failed, step_id, reason}}
    end
  end

  defp execute_cmd(program, args, cwd, env) do
    case System.find_executable(program) do
      nil ->
        {:error, {:not_found, program}}

      _ ->
        muon_opts =
          [cd: cwd, stderr_to_stdout: true]
          |> then(fn o -> if env == [], do: o, else: o ++ [env: env] end)

        {output, exit_code} = MuonTrap.cmd(program, Enum.map(args, &to_string/1), muon_opts)
        {:ok, output, exit_code}
    end
  end

  defp normalize_env(nil), do: []

  defp normalize_env(map) when is_map(map),
    do: Enum.map(map, fn {k, v} -> {to_string(k), to_string(v)} end)

  ## http

  defp run_http(step_id, step, state) do
    fields = Map.take(step, ["method", "url", "headers", "body", "expect_status"])

    case interpolate(fields, state) do
      {:ok, resolved} ->
        method = resolved |> Map.fetch!("method") |> String.downcase() |> String.to_atom()
        url = Map.fetch!(resolved, "url")
        headers = resolved |> Map.get("headers", %{}) |> Enum.map(&header_pair/1)
        body = Map.get(resolved, "body")

        req_opts =
          [method: method, url: url, headers: headers, retry: false]
          |> maybe_put_body(body)
          |> Keyword.merge(Keyword.get(state.opts, :req_options, []))

        case Req.request(req_opts) do
          {:ok, %Req.Response{} = response} ->
            output = %{
              "status" => response.status,
              "headers" => Map.new(response.headers, fn {k, v} -> {k, normalize_header_value(v)} end),
              "body" => response.body
            }

            case enforce_expect_status(resolved, output) do
              :ok -> record(state, step_id, output)
              {:error, reason} -> {:error, {:http_unexpected_status, step_id, reason}}
            end

          {:error, reason} ->
            {:error, {:http_failed, step_id, reason}}
        end

      {:error, reason} ->
        {:error, {:interpolate_failed, step_id, reason}}
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
      nil -> :ok
      ^status -> :ok
      expected when is_integer(expected) -> {:error, {:expected, expected, :got, status}}
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

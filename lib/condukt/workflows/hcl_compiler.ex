defmodule Condukt.Workflows.HCLCompiler do
  @moduledoc """
  Normalizes HCL workflow files to canonical workflow documents.

  HCL is the human-authored workflow format. It keeps the DAG visible by
  requiring every `task.<id>` reference inside a step to also appear in
  that step's `needs` list. The normalized document is still the same
  shape used by the executor, schema validator, and visual tooling.
  """

  alias Condukt.Workflows.Expr
  alias HXL.Ast.AccessOperation
  alias HXL.Ast.Attr
  alias HXL.Ast.Binary
  alias HXL.Ast.Block
  alias HXL.Ast.Body
  alias HXL.Ast.Comment
  alias HXL.Ast.Conditional
  alias HXL.Ast.ForExpr
  alias HXL.Ast.FunctionCall
  alias HXL.Ast.Identifier
  alias HXL.Ast.Literal
  alias HXL.Ast.Object
  alias HXL.Ast.TemplateExpr
  alias HXL.Ast.Tuple, as: HCLTuple
  alias HXL.Ast.Unary

  @step_types ~w(cmd agent http tool map)
  @input_attrs ~w(type description default enum items)
  @runtime_attrs ~w(model sandbox cwd)
  @common_step_attrs ~w(needs when)
  @step_attrs %{
    "agent" => @common_step_attrs ++ ~w(model input tools system output_schema),
    "cmd" => @common_step_attrs ++ ~w(argv cwd env),
    "http" => @common_step_attrs ++ ~w(method url headers body expect_status),
    "map" => @common_step_attrs ++ ~w(over as concurrency),
    "tool" => @common_step_attrs ++ ~w(id args)
  }

  @doc """
  Reads, parses, and normalizes an HCL workflow file.
  """
  @spec compile(Path.t()) :: {:ok, map()} | {:error, term()}
  def compile(path) when is_binary(path) do
    with {:ok, source} <- read(path) do
      compile_string(source, path)
    end
  end

  @doc """
  Normalizes HCL source into a workflow document. `path` is used only for
  diagnostics.
  """
  @spec compile_string(String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def compile_string(source, path \\ "<hcl>") when is_binary(source) do
    with {:ok, ast} <- parse(source, path),
         {:ok, doc} <- compile_body(ast, path),
         :ok <- enforce_explicit_needs(doc) do
      {:ok, doc}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp parse(source, path) do
    {result, _diagnostics} = Code.with_diagnostics(fn -> HXL.decode_as_ast(source) end)

    case result do
      {:ok, %Body{} = ast} -> {:ok, ast}
      {:error, reason} -> {:error, {:parse_failed, path, reason}}
      other -> {:error, {:parse_failed, path, other}}
    end
  end

  defp compile_body(%Body{} = body, path) do
    statements = statements(body)

    workflow_blocks =
      Enum.filter(statements, fn
        %Block{type: "workflow"} -> true
        _ -> false
      end)

    non_workflow = statements -- workflow_blocks

    cond do
      workflow_blocks == [] ->
        {:error, {:missing_workflow, path}}

      length(workflow_blocks) > 1 ->
        {:error, {:multiple_workflows, path}}

      non_workflow != [] ->
        {:error, {:unsupported_top_level_statement, path, hd(non_workflow)}}

      true ->
        compile_workflow(hd(workflow_blocks), path)
    end
  end

  defp compile_workflow(%Block{labels: [name], body: body}, path) when is_binary(name) do
    base = %{"name" => name, "steps" => %{}}

    body
    |> statements()
    |> Enum.reduce_while({:ok, base}, fn
      %Block{type: "input", labels: [id]} = block, {:ok, doc} ->
        with {:ok, input} <- compile_input(block, path),
             {:ok, inputs} <- put_unique(Map.get(doc, "inputs", %{}), id, input, {:duplicate_input, path, id}) do
          {:cont, {:ok, Map.put(doc, "inputs", inputs)}}
        else
          {:error, _} = err -> {:halt, err}
        end

      %Block{type: "runtime", labels: []} = block, {:ok, doc} ->
        if Map.has_key?(doc, "runtime") do
          {:halt, {:error, {:duplicate_runtime, path}}}
        else
          case compile_runtime(block, path) do
            {:ok, runtime} -> {:cont, {:ok, Map.put(doc, "runtime", runtime)}}
            {:error, _} = err -> {:halt, err}
          end
        end

      %Block{type: type, labels: [id]} = block, {:ok, doc} when type in @step_types ->
        with {:ok, step} <- compile_step(block, path, :named),
             {:ok, steps} <- put_unique(doc["steps"], id, step, {:duplicate_step, path, id}) do
          {:cont, {:ok, Map.put(doc, "steps", steps)}}
        else
          {:error, _} = err -> {:halt, err}
        end

      %Attr{name: "output", expr: expr}, {:ok, doc} ->
        if Map.has_key?(doc, "output") do
          {:halt, {:error, {:duplicate_attr, path, "output"}}}
        else
          case value(expr) do
            {:ok, output} -> {:cont, {:ok, Map.put(doc, "output", output)}}
            {:error, _} = err -> {:halt, err}
          end
        end

      statement, {:ok, _doc} ->
        {:halt, {:error, {:unsupported_workflow_statement, path, statement}}}
    end)
  end

  defp compile_workflow(%Block{labels: labels}, path), do: {:error, {:invalid_workflow_labels, path, labels}}

  defp compile_runtime(%Block{type: "runtime", body: body}, path) do
    with {:ok, attrs, blocks} <- split_body(body, path),
         :ok <- reject_blocks(blocks, {:runtime_cannot_have_blocks, path}),
         :ok <- reject_unknown_attrs(attrs, @runtime_attrs, {:unknown_runtime_attr, path}) do
      map_values(attrs, &value/1)
    end
  end

  defp compile_input(%Block{type: "input", labels: [id], body: body}, path) do
    with {:ok, attrs, blocks} <- split_body(body, path),
         :ok <- reject_blocks(blocks, {:input_cannot_have_blocks, path, id}),
         :ok <- reject_unknown_attrs(attrs, @input_attrs, {:unknown_input_attr, path, id}) do
      map_values(attrs, &value/1)
    end
  end

  defp compile_step(%Block{type: type, labels: labels, body: body}, path, mode) when type in @step_types do
    with :ok <- validate_step_labels(type, labels, mode, path),
         {:ok, attrs, blocks} <- split_body(body, path),
         :ok <- reject_unknown_attrs(attrs, @step_attrs[type], {:unknown_step_attr, path, type, labels}),
         {:ok, common} <- compile_common_step_attrs(type, attrs),
         {:ok, specific} <- compile_specific_step_attrs(type, attrs, blocks, path) do
      {:ok, Map.merge(common, specific)}
    end
  end

  defp compile_common_step_attrs(type, attrs) do
    base = %{"kind" => type}

    with {:ok, base} <- maybe_value_attr(base, attrs, "needs") do
      maybe_expression_attr(base, attrs, "when")
    end
  end

  defp compile_specific_step_attrs("cmd", attrs, blocks, path) do
    with :ok <- reject_blocks(blocks, {:step_cannot_have_blocks, path, "cmd"}),
         {:ok, step} <- required_value_attr(%{}, attrs, "argv", path, "cmd"),
         {:ok, step} <- maybe_value_attr(step, attrs, "cwd") do
      maybe_value_attr(step, attrs, "env")
    end
  end

  defp compile_specific_step_attrs("http", attrs, blocks, path) do
    with :ok <- reject_blocks(blocks, {:step_cannot_have_blocks, path, "http"}),
         {:ok, step} <- required_value_attr(%{}, attrs, "method", path, "http"),
         {:ok, step} <- required_value_attr(step, attrs, "url", path, "http"),
         {:ok, step} <- maybe_value_attr(step, attrs, "headers"),
         {:ok, step} <- maybe_value_attr(step, attrs, "body"),
         {:ok, step} <- maybe_value_attr(step, attrs, "expect_status") do
      {:ok, uppercase_method(step)}
    end
  end

  defp compile_specific_step_attrs("agent", attrs, blocks, path) do
    with :ok <- reject_blocks(blocks, {:step_cannot_have_blocks, path, "agent"}),
         {:ok, step} <- required_value_attr(%{}, attrs, "input", path, "agent"),
         {:ok, step} <- maybe_value_attr(step, attrs, "model"),
         {:ok, step} <- maybe_value_attr(step, attrs, "tools"),
         {:ok, step} <- maybe_value_attr(step, attrs, "system") do
      maybe_value_attr(step, attrs, "output_schema")
    end
  end

  defp compile_specific_step_attrs("tool", attrs, blocks, path) do
    with :ok <- reject_blocks(blocks, {:step_cannot_have_blocks, path, "tool"}),
         {:ok, step} <- required_value_attr(%{}, attrs, "id", path, "tool") do
      maybe_value_attr(step, attrs, "args")
    end
  end

  defp compile_specific_step_attrs("map", attrs, blocks, path) do
    with {:ok, step} <- required_value_attr(%{}, attrs, "over", path, "map"),
         {:ok, step} <- required_value_attr(step, attrs, "as", path, "map"),
         {:ok, step} <- maybe_value_attr(step, attrs, "concurrency"),
         {:ok, inner} <- compile_map_inner(blocks, path) do
      {:ok, Map.put(step, "do", inner)}
    end
  end

  defp compile_map_inner([%Block{type: type, labels: []} = block], path) when type in @step_types do
    compile_step(block, path, :anonymous)
  end

  defp compile_map_inner([], path), do: {:error, {:missing_map_step, path}}

  defp compile_map_inner([%Block{type: type, labels: labels}], path),
    do: {:error, {:invalid_map_step, path, type, labels}}

  defp compile_map_inner(blocks, path), do: {:error, {:multiple_map_steps, path, blocks}}

  defp validate_step_labels(_type, [_id], :named, _path), do: :ok
  defp validate_step_labels(type, labels, :named, path), do: {:error, {:invalid_step_labels, path, type, labels}}
  defp validate_step_labels(_type, [], :anonymous, _path), do: :ok

  defp validate_step_labels(type, labels, :anonymous, path),
    do: {:error, {:anonymous_step_has_labels, path, type, labels}}

  defp statements(%Body{statements: statements}) do
    Enum.reject(statements, &match?(%Comment{}, &1))
  end

  defp split_body(%Body{} = body, path) do
    body
    |> statements()
    |> Enum.reduce_while({:ok, %{}, []}, fn
      %Attr{name: name, expr: expr}, {:ok, attrs, blocks} ->
        if Map.has_key?(attrs, name) do
          {:halt, {:error, {:duplicate_attr, path, name}}}
        else
          {:cont, {:ok, Map.put(attrs, name, expr), blocks}}
        end

      %Block{} = block, {:ok, attrs, blocks} ->
        {:cont, {:ok, attrs, [block | blocks]}}
    end)
    |> case do
      {:ok, attrs, blocks} -> {:ok, attrs, Enum.reverse(blocks)}
      {:error, _} = err -> err
    end
  end

  defp reject_blocks([], _reason), do: :ok
  defp reject_blocks(_blocks, reason), do: {:error, reason}

  defp reject_unknown_attrs(attrs, allowed, reason) do
    unknown = Map.keys(attrs) -- allowed

    case unknown do
      [] -> :ok
      _ -> {:error, append_tuple(reason, unknown)}
    end
  end

  defp put_unique(map, key, value, reason) do
    if Map.has_key?(map, key) do
      {:error, reason}
    else
      {:ok, Map.put(map, key, value)}
    end
  end

  defp required_value_attr(step, attrs, key, path, type) do
    case Map.fetch(attrs, key) do
      {:ok, expr} ->
        with {:ok, compiled} <- value(expr) do
          {:ok, Map.put(step, key, compiled)}
        end

      :error ->
        {:error, {:missing_attr, path, type, key}}
    end
  end

  defp maybe_value_attr(step, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, expr} ->
        with {:ok, compiled} <- value(expr) do
          {:ok, Map.put(step, key, compiled)}
        end

      :error ->
        {:ok, step}
    end
  end

  defp maybe_expression_attr(step, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, expr} ->
        with {:ok, compiled} <- interpolation(expr) do
          {:ok, Map.put(step, key, compiled)}
        end

      :error ->
        {:ok, step}
    end
  end

  defp uppercase_method(%{"method" => method} = step) when is_binary(method),
    do: Map.put(step, "method", String.upcase(method))

  defp uppercase_method(step), do: step

  defp value(%TemplateExpr{lines: lines}) do
    lines
    |> Enum.reduce_while({:ok, []}, fn
      {:string_part, text}, {:ok, acc} ->
        {:cont, {:ok, [text | acc]}}

      expr, {:ok, acc} ->
        case expression(expr) do
          {:ok, text} -> {:cont, {:ok, ["}", text, "${" | acc]}}
          {:error, _} = err -> {:halt, err}
        end
    end)
    |> case do
      {:ok, parts} -> {:ok, IO.iodata_to_binary(Enum.reverse(parts))}
      {:error, _} = err -> err
    end
  end

  defp value(%HCLTuple{values: values}) do
    list_map(values, &value/1)
  end

  defp value(%Object{kvs: kvs}) do
    map_values(kvs, &value/1)
  end

  defp value(%Literal{value: {:bool, value}}), do: {:ok, value}
  defp value(%Literal{value: {:decimal, value}}), do: {:ok, value}
  defp value(%Literal{value: {:int, value}}), do: {:ok, value}
  defp value(%Literal{value: {:null, nil}}), do: {:ok, nil}

  defp value(%Unary{operator: :-, expr: %Literal{value: {:int, value}}}), do: {:ok, -value}
  defp value(%Unary{operator: :-, expr: %Literal{value: {:decimal, value}}}), do: {:ok, -value}

  defp value(%AccessOperation{} = expr), do: interpolation(expr)
  defp value(%Binary{} = expr), do: interpolation(expr)
  defp value(%Identifier{} = expr), do: interpolation(expr)
  defp value(%Unary{} = expr), do: interpolation(expr)

  defp value(%Conditional{}), do: {:error, :unsupported_conditional_expression}
  defp value(%ForExpr{}), do: {:error, :unsupported_for_expression}
  defp value(%FunctionCall{}), do: {:error, :unsupported_function_call}
  defp value(other), do: {:error, {:unsupported_expression, other}}

  defp interpolation(expr) do
    with {:ok, text} <- expression(expr) do
      {:ok, "${" <> text <> "}"}
    end
  end

  defp expression(%Identifier{name: "input"}), do: {:ok, "inputs"}
  defp expression(%Identifier{name: "task"}), do: {:ok, "steps"}
  defp expression(%Identifier{name: name}) when is_binary(name), do: {:ok, name}

  defp expression(%AccessOperation{operation: :attr_access, expr: expr, key: key}) do
    with {:ok, target} <- expression(expr) do
      {:ok, target <> "." <> key}
    end
  end

  defp expression(%AccessOperation{operation: :index_access, expr: expr, key: key}) do
    with {:ok, target} <- expression(expr),
         {:ok, index} <- expression(key) do
      {:ok, target <> "[" <> index <> "]"}
    end
  end

  defp expression(%Binary{operator: operator, left: left, right: right}) do
    with {:ok, left} <- expression(left),
         {:ok, right} <- expression(right),
         {:ok, operator} <- binary_operator(operator) do
      {:ok, left <> " " <> operator <> " " <> right}
    end
  end

  defp expression(%Unary{operator: :!, expr: expr}) do
    with {:ok, text} <- expression(expr) do
      {:ok, "!" <> text}
    end
  end

  defp expression(%Unary{operator: :-, expr: expr}) do
    with {:ok, text} <- expression(expr) do
      {:ok, "-" <> text}
    end
  end

  defp expression(%Literal{value: {:bool, true}}), do: {:ok, "true"}
  defp expression(%Literal{value: {:bool, false}}), do: {:ok, "false"}
  defp expression(%Literal{value: {:decimal, value}}), do: {:ok, to_string(value)}
  defp expression(%Literal{value: {:int, value}}), do: {:ok, Integer.to_string(value)}
  defp expression(%Literal{value: {:null, nil}}), do: {:ok, "null"}

  defp expression(%TemplateExpr{lines: [string_part: string]}), do: {:ok, JSON.encode!(string)}
  defp expression(%TemplateExpr{}), do: {:error, :template_string_not_allowed_in_expression}
  defp expression(%Conditional{}), do: {:error, :unsupported_conditional_expression}
  defp expression(%ForExpr{}), do: {:error, :unsupported_for_expression}
  defp expression(%FunctionCall{}), do: {:error, :unsupported_function_call}
  defp expression(other), do: {:error, {:unsupported_expression, other}}

  defp binary_operator(:==), do: {:ok, "=="}
  defp binary_operator(:!=), do: {:ok, "!="}
  defp binary_operator(:<), do: {:ok, "<"}
  defp binary_operator(:<=), do: {:ok, "<="}
  defp binary_operator(:>), do: {:ok, ">"}
  defp binary_operator(:>=), do: {:ok, ">="}
  defp binary_operator(:&&), do: {:ok, "&&"}
  defp binary_operator(:||), do: {:ok, "||"}
  defp binary_operator(operator), do: {:error, {:unsupported_operator, operator}}

  defp enforce_explicit_needs(%{"steps" => steps}) do
    Enum.reduce_while(steps, :ok, fn {id, step}, :ok ->
      declared = Map.get(step, "needs", [])

      missing =
        step
        |> Expr.references()
        |> Enum.reject(&(&1 in declared))

      case missing do
        [] -> {:cont, :ok}
        _ -> {:halt, {:error, {:missing_needs, id, missing}}}
      end
    end)
  end

  defp list_map(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = err -> err
    end
  end

  defp map_values(map, fun) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case fun.(value) do
        {:ok, compiled} -> {:cont, {:ok, Map.put(acc, key, compiled)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp append_tuple(tuple, value) do
    tuple
    |> Tuple.to_list()
    |> Kernel.++([value])
    |> List.to_tuple()
  end
end

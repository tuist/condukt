defmodule Condukt.Workflows.Expr do
  @moduledoc """
  Expression sub-language for Condukt workflows.

  Workflow document fields contain `${...}` placeholders that reference
  inputs, prior step outputs, and `as` bindings introduced by `map`
  steps. Inside a placeholder, the language supports:

  - identifiers: `inputs`, `steps`, plus any binding in scope
  - member access: `inputs.name`, `steps.fetch.body.title`
  - indexing: `xs[0]`, `obj["key"]`
  - comparison: `==`, `!=`, `<`, `<=`, `>`, `>=`
  - boolean: `&&`, `||`, `!`
  - literals: strings, integers, floats, booleans, null
  - formatters: `${var:json}`, `${var:csv}`

  When a string field is exactly one `${expr}` placeholder, the
  underlying value's type is preserved. Otherwise every placeholder is
  coerced to a string and concatenated with the surrounding text.
  """

  @type context :: %{
          optional(:inputs) => map(),
          optional(:steps) => map(),
          optional(:bindings) => map()
        }

  @type ast ::
          {:literal, term()}
          | {:identifier, String.t()}
          | {:member, ast(), String.t()}
          | {:index, ast(), ast()}
          | {:not, ast()}
          | {:bin_op, atom(), ast(), ast()}
          | {:format, ast(), :json | :csv}

  ## Public API

  @doc """
  Recursively interpolates `${...}` placeholders inside any JSON
  value: strings, lists, and maps. Non-string leaves are passed
  through unchanged.
  """
  @spec interpolate_value(term(), context()) :: {:ok, term()} | {:error, term()}
  def interpolate_value(value, ctx) when is_binary(value), do: interpolate(value, ctx)
  def interpolate_value(values, ctx) when is_list(values), do: list_map(values, &interpolate_value(&1, ctx))
  def interpolate_value(%_{} = struct, _ctx), do: {:ok, struct}

  def interpolate_value(map, ctx) when is_map(map),
    do: map_values(map, &interpolate_value(&1, ctx))

  def interpolate_value(other, _ctx), do: {:ok, other}

  @doc """
  Interpolates a single string. See module docs for the
  type-preservation rule.
  """
  @spec interpolate(String.t(), context()) :: {:ok, term()} | {:error, term()}
  def interpolate(string, ctx) when is_binary(string) do
    case scan(string, []) do
      {:ok, segments} -> emit(segments, ctx)
      {:error, _} = err -> err
    end
  end

  @doc """
  Parses an expression string (the contents of a `${...}` placeholder)
  into an AST.
  """
  @spec parse(String.t()) :: {:ok, ast()} | {:error, term()}
  def parse(expression_text) when is_binary(expression_text) do
    with {:ok, tokens} <- tokenize(expression_text, []),
         {:ok, ast, []} <- parse_top_level(tokens) do
      {:ok, ast}
    else
      {:error, _} = err -> err
      {:ok, _ast, rest} -> {:error, {:trailing_tokens, rest}}
    end
  end

  @doc "Evaluates an expression AST against `ctx`."
  @spec eval(ast(), context()) :: {:ok, term()} | {:error, term()}
  def eval(ast, ctx), do: do_eval(ast, ctx)

  @doc """
  Returns the sorted list of step ids referenced inside any `${...}`
  placeholder anywhere in `value`. Used by the executor to infer
  implicit dependencies between steps.
  """
  @spec references(term()) :: [String.t()]
  def references(value) do
    value
    |> collect_strings([])
    |> Enum.flat_map(&extract_step_refs/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  ## Scanner: split a string into [text, placeholder] segments.

  defp scan(string, acc) do
    case :binary.split(string, "${") do
      [text] ->
        {:ok, Enum.reverse([{:text, text} | acc])}

      [before, rest] ->
        case find_closing_brace(rest, "", 0) do
          {:ok, inner, after_brace} ->
            scan(after_brace, [{:placeholder, inner}, {:text, before} | acc])

          {:error, _} = err ->
            err
        end
    end
  end

  defp find_closing_brace("", _acc, _depth), do: {:error, :unclosed_placeholder}

  defp find_closing_brace("\"" <> rest, acc, depth) do
    case skip_string(rest, []) do
      {:ok, consumed, rest2} -> find_closing_brace(rest2, acc <> "\"" <> consumed, depth)
      {:error, _} = err -> err
    end
  end

  defp find_closing_brace("{" <> rest, acc, depth),
    do: find_closing_brace(rest, acc <> "{", depth + 1)

  defp find_closing_brace("}" <> rest, acc, 0), do: {:ok, acc, rest}

  defp find_closing_brace("}" <> rest, acc, depth),
    do: find_closing_brace(rest, acc <> "}", depth - 1)

  defp find_closing_brace(<<c::utf8, rest::binary>>, acc, depth),
    do: find_closing_brace(rest, acc <> <<c::utf8>>, depth)

  defp skip_string("", _acc), do: {:error, :unterminated_string}

  defp skip_string("\\" <> <<c::utf8, rest::binary>>, acc),
    do: skip_string(rest, [acc, "\\", <<c::utf8>>])

  defp skip_string("\"" <> rest, acc),
    do: {:ok, IO.iodata_to_binary([acc, "\""]), rest}

  defp skip_string(<<c::utf8, rest::binary>>, acc),
    do: skip_string(rest, [acc, <<c::utf8>>])

  defp emit([{:text, text}], _ctx), do: {:ok, text}

  defp emit([{:text, ""}, {:placeholder, expr_text}, {:text, ""}], ctx) do
    parse_and_eval(expr_text, ctx)
  end

  defp emit(segments, ctx) do
    Enum.reduce_while(segments, {:ok, ""}, fn
      {:text, text}, {:ok, acc} ->
        {:cont, {:ok, acc <> text}}

      {:placeholder, expr_text}, {:ok, acc} ->
        case parse_and_eval(expr_text, ctx) do
          {:ok, value} -> {:cont, {:ok, acc <> stringify(value)}}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  defp parse_and_eval(text, ctx) do
    with {:ok, ast} <- parse(text) do
      eval(ast, ctx)
    end
  end

  defp stringify(nil), do: ""
  defp stringify(true), do: "true"
  defp stringify(false), do: "false"
  defp stringify(s) when is_binary(s), do: s
  defp stringify(n) when is_number(n), do: to_string(n)
  defp stringify(other), do: JSON.encode!(other)

  ## Tokenizer

  defp tokenize("", acc), do: {:ok, Enum.reverse([{:eof} | acc])}

  defp tokenize(<<c::utf8, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r],
    do: tokenize(rest, acc)

  defp tokenize("==" <> rest, acc), do: tokenize(rest, [{:op, :eq} | acc])
  defp tokenize("!=" <> rest, acc), do: tokenize(rest, [{:op, :neq} | acc])
  defp tokenize("<=" <> rest, acc), do: tokenize(rest, [{:op, :le} | acc])
  defp tokenize(">=" <> rest, acc), do: tokenize(rest, [{:op, :ge} | acc])
  defp tokenize("&&" <> rest, acc), do: tokenize(rest, [{:op, :and} | acc])
  defp tokenize("||" <> rest, acc), do: tokenize(rest, [{:op, :or} | acc])
  defp tokenize("<" <> rest, acc), do: tokenize(rest, [{:op, :lt} | acc])
  defp tokenize(">" <> rest, acc), do: tokenize(rest, [{:op, :gt} | acc])
  defp tokenize("!" <> rest, acc), do: tokenize(rest, [{:op, :not} | acc])
  defp tokenize("-" <> rest, acc), do: tokenize(rest, [{:op, :neg} | acc])
  defp tokenize("." <> rest, acc), do: tokenize(rest, [{:dot} | acc])
  defp tokenize("[" <> rest, acc), do: tokenize(rest, [{:lbracket} | acc])
  defp tokenize("]" <> rest, acc), do: tokenize(rest, [{:rbracket} | acc])
  defp tokenize("(" <> rest, acc), do: tokenize(rest, [{:lparen} | acc])
  defp tokenize(")" <> rest, acc), do: tokenize(rest, [{:rparen} | acc])
  defp tokenize(":" <> rest, acc), do: tokenize(rest, [{:colon} | acc])

  defp tokenize("\"" <> rest, acc) do
    case parse_string_literal(rest, []) do
      {:ok, value, rest2} -> tokenize(rest2, [{:string, value} | acc])
      {:error, _} = err -> err
    end
  end

  defp tokenize(<<c, _::binary>> = source, acc) when c in ?0..?9 do
    case parse_number_literal(source, []) do
      {:ok, value, rest} -> tokenize(rest, [{:number, value} | acc])
      {:error, _} = err -> err
    end
  end

  defp tokenize(<<c, _::binary>> = source, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {ident, rest} = parse_ident_chars(source, [])

    token =
      case ident do
        "true" -> {:bool, true}
        "false" -> {:bool, false}
        "null" -> {:null}
        other -> {:ident, other}
      end

    tokenize(rest, [token | acc])
  end

  defp tokenize(<<c::utf8, _::binary>>, _acc),
    do: {:error, {:unexpected_char, <<c::utf8>>}}

  defp parse_string_literal("", _acc), do: {:error, :unterminated_string}

  defp parse_string_literal("\"" <> rest, acc),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp parse_string_literal("\\\"" <> rest, acc),
    do: parse_string_literal(rest, ["\"" | acc])

  defp parse_string_literal("\\\\" <> rest, acc),
    do: parse_string_literal(rest, ["\\" | acc])

  defp parse_string_literal("\\n" <> rest, acc),
    do: parse_string_literal(rest, ["\n" | acc])

  defp parse_string_literal("\\t" <> rest, acc),
    do: parse_string_literal(rest, ["\t" | acc])

  defp parse_string_literal("\\r" <> rest, acc),
    do: parse_string_literal(rest, ["\r" | acc])

  defp parse_string_literal(<<c::utf8, rest::binary>>, acc),
    do: parse_string_literal(rest, [<<c::utf8>> | acc])

  defp parse_number_literal(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: parse_number_literal(rest, [c | acc])

  defp parse_number_literal(<<?., c, rest::binary>>, acc) when c in ?0..?9,
    do: parse_number_float(rest, [c, ?. | acc])

  defp parse_number_literal(rest, acc) do
    case Integer.parse(IO.iodata_to_binary(Enum.reverse(acc))) do
      {n, ""} -> {:ok, n, rest}
      _ -> {:error, :invalid_number}
    end
  end

  defp parse_number_float(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: parse_number_float(rest, [c | acc])

  defp parse_number_float(rest, acc) do
    case Float.parse(IO.iodata_to_binary(Enum.reverse(acc))) do
      {f, ""} -> {:ok, f, rest}
      _ -> {:error, :invalid_number}
    end
  end

  defp parse_ident_chars(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c in ?0..?9,
       do: parse_ident_chars(rest, [c | acc])

  defp parse_ident_chars(rest, acc),
    do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  ## Parser: recursive descent.

  defp parse_top_level(tokens) do
    with {:ok, ast, rest} <- parse_or(tokens) do
      case rest do
        [{:colon}, {:ident, "json"}, {:eof}] -> {:ok, {:format, ast, :json}, []}
        [{:colon}, {:ident, "csv"}, {:eof}] -> {:ok, {:format, ast, :csv}, []}
        [{:colon}, {:ident, name} | _] -> {:error, {:unknown_formatter, name}}
        [{:eof}] -> {:ok, ast, []}
        _ -> {:error, {:unexpected_tokens, rest}}
      end
    end
  end

  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens), do: parse_or_tail(left, rest)
  end

  defp parse_or_tail(left, [{:op, :or} | rest]) do
    with {:ok, right, rest2} <- parse_and(rest),
         do: parse_or_tail({:bin_op, :or, left, right}, rest2)
  end

  defp parse_or_tail(left, rest), do: {:ok, left, rest}

  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_unary(tokens), do: parse_and_tail(left, rest)
  end

  defp parse_and_tail(left, [{:op, :and} | rest]) do
    with {:ok, right, rest2} <- parse_unary(rest),
         do: parse_and_tail({:bin_op, :and, left, right}, rest2)
  end

  defp parse_and_tail(left, rest), do: {:ok, left, rest}

  defp parse_unary([{:op, :not} | rest]) do
    with {:ok, ast, rest2} <- parse_unary(rest), do: {:ok, {:not, ast}, rest2}
  end

  defp parse_unary([{:op, :neg} | rest]) do
    with {:ok, ast, rest2} <- parse_unary(rest), do: {:ok, {:neg, ast}, rest2}
  end

  defp parse_unary(tokens), do: parse_comparison(tokens)

  defp parse_comparison(tokens) do
    with {:ok, left, rest} <- parse_postfix(tokens) do
      case rest do
        [{:op, op} | rest2] when op in [:eq, :neq, :lt, :le, :gt, :ge] ->
          with {:ok, right, rest3} <- parse_postfix(rest2),
               do: {:ok, {:bin_op, op, left, right}, rest3}

        _ ->
          {:ok, left, rest}
      end
    end
  end

  defp parse_postfix(tokens) do
    with {:ok, ast, rest} <- parse_primary(tokens), do: parse_postfix_tail(ast, rest)
  end

  defp parse_postfix_tail(ast, [{:dot}, {:ident, name} | rest]),
    do: parse_postfix_tail({:member, ast, name}, rest)

  defp parse_postfix_tail(ast, [{:lbracket} | rest]) do
    with {:ok, index, rest2} <- parse_or(rest) do
      case rest2 do
        [{:rbracket} | rest3] -> parse_postfix_tail({:index, ast, index}, rest3)
        _ -> {:error, :missing_rbracket}
      end
    end
  end

  defp parse_postfix_tail(ast, rest), do: {:ok, ast, rest}

  defp parse_primary([{:string, s} | rest]), do: {:ok, {:literal, s}, rest}
  defp parse_primary([{:number, n} | rest]), do: {:ok, {:literal, n}, rest}
  defp parse_primary([{:bool, b} | rest]), do: {:ok, {:literal, b}, rest}
  defp parse_primary([{:null} | rest]), do: {:ok, {:literal, nil}, rest}
  defp parse_primary([{:ident, name} | rest]), do: {:ok, {:identifier, name}, rest}

  defp parse_primary([{:lparen} | rest]) do
    with {:ok, ast, rest2} <- parse_or(rest) do
      case rest2 do
        [{:rparen} | rest3] -> {:ok, ast, rest3}
        _ -> {:error, :missing_rparen}
      end
    end
  end

  defp parse_primary(other), do: {:error, {:unexpected_tokens, other}}

  ## Evaluator

  defp do_eval({:literal, v}, _ctx), do: {:ok, v}

  defp do_eval({:identifier, "inputs"}, ctx), do: {:ok, Map.get(ctx, :inputs, %{})}
  defp do_eval({:identifier, "steps"}, ctx), do: {:ok, Map.get(ctx, :steps, %{})}

  defp do_eval({:identifier, name}, ctx) do
    bindings = Map.get(ctx, :bindings, %{})

    case Map.fetch(bindings, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:undefined_identifier, name}}
    end
  end

  defp do_eval({:member, target_ast, name}, ctx) do
    with {:ok, target} <- do_eval(target_ast, ctx) do
      case target do
        m when is_map(m) ->
          case Map.fetch(m, name) do
            {:ok, value} -> {:ok, value}
            :error -> {:error, {:undefined_member, name}}
          end

        nil ->
          {:error, {:nil_member_access, name}}

        _ ->
          {:error, {:not_an_object, name}}
      end
    end
  end

  defp do_eval({:index, target_ast, index_ast}, ctx) do
    with {:ok, target} <- do_eval(target_ast, ctx),
         {:ok, index} <- do_eval(index_ast, ctx) do
      case {target, index} do
        {list, i} when is_list(list) and is_integer(i) ->
          case fetch_at(list, i) do
            {:ok, v} -> {:ok, v}
            :error -> {:error, {:index_out_of_range, i}}
          end

        {map, key} when is_map(map) and is_binary(key) ->
          case Map.fetch(map, key) do
            {:ok, value} -> {:ok, value}
            :error -> {:error, {:undefined_key, key}}
          end

        _ ->
          {:error, {:invalid_index, index}}
      end
    end
  end

  defp do_eval({:not, ast}, ctx) do
    with {:ok, value} <- do_eval(ast, ctx), do: {:ok, !truthy?(value)}
  end

  defp do_eval({:neg, ast}, ctx) do
    with {:ok, value} <- do_eval(ast, ctx) do
      case value do
        n when is_number(n) -> {:ok, -n}
        _ -> {:error, {:negate_non_number, value}}
      end
    end
  end

  defp do_eval({:bin_op, :and, l, r}, ctx) do
    with {:ok, lv} <- do_eval(l, ctx) do
      if truthy?(lv) do
        with {:ok, rv} <- do_eval(r, ctx), do: {:ok, truthy?(rv)}
      else
        {:ok, false}
      end
    end
  end

  defp do_eval({:bin_op, :or, l, r}, ctx) do
    with {:ok, lv} <- do_eval(l, ctx) do
      if truthy?(lv) do
        {:ok, true}
      else
        with {:ok, rv} <- do_eval(r, ctx), do: {:ok, truthy?(rv)}
      end
    end
  end

  defp do_eval({:bin_op, op, l, r}, ctx) do
    with {:ok, lv} <- do_eval(l, ctx),
         {:ok, rv} <- do_eval(r, ctx),
         do: compare(op, lv, rv)
  end

  defp do_eval({:format, ast, :json}, ctx) do
    with {:ok, v} <- do_eval(ast, ctx), do: {:ok, JSON.encode!(v)}
  end

  defp do_eval({:format, ast, :csv}, ctx) do
    with {:ok, v} <- do_eval(ast, ctx) do
      case v do
        list when is_list(list) ->
          {:ok, list |> Enum.map(&csv_field/1) |> Enum.join(",")}

        _ ->
          {:error, {:csv_requires_list, v}}
      end
    end
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(""), do: false
  defp truthy?([]), do: false
  defp truthy?(0), do: false
  defp truthy?(+0.0), do: false
  defp truthy?(-0.0), do: false
  defp truthy?(_), do: true

  defp compare(:eq, a, b), do: {:ok, a == b}
  defp compare(:neq, a, b), do: {:ok, a != b}

  defp compare(op, a, b) when is_number(a) and is_number(b) do
    {:ok,
     case op do
       :lt -> a < b
       :le -> a <= b
       :gt -> a > b
       :ge -> a >= b
     end}
  end

  defp compare(op, a, b) when is_binary(a) and is_binary(b) do
    {:ok,
     case op do
       :lt -> a < b
       :le -> a <= b
       :gt -> a > b
       :ge -> a >= b
     end}
  end

  defp compare(op, a, b), do: {:error, {:incompatible_compare, op, a, b}}

  defp csv_field(v) when is_binary(v), do: csv_quote(v)
  defp csv_field(v), do: csv_quote(JSON.encode!(v))

  defp csv_quote(s) do
    if String.contains?(s, [",", "\n", "\r", "\""]) do
      "\"" <> String.replace(s, "\"", "\"\"") <> "\""
    else
      s
    end
  end

  defp fetch_at(list, i) when i >= 0 do
    case Enum.split(list, i) do
      {_, [v | _]} -> {:ok, v}
      _ -> :error
    end
  end

  defp fetch_at(list, i) when i < 0 do
    len = length(list)

    if -i <= len do
      {:ok, Enum.at(list, len + i)}
    else
      :error
    end
  end

  ## Reference extraction

  defp list_map(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp map_values(map, fun) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case fun.(v) do
        {:ok, new_v} -> {:cont, {:ok, Map.put(acc, k, new_v)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp collect_strings(s, acc) when is_binary(s), do: [s | acc]

  defp collect_strings(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_strings/2)

  defp collect_strings(map, acc) when is_map(map),
    do: Enum.reduce(map, acc, fn {_k, v}, a -> collect_strings(v, a) end)

  defp collect_strings(_, acc), do: acc

  defp extract_step_refs(string) do
    case scan(string, []) do
      {:ok, segments} ->
        Enum.flat_map(segments, fn
          {:placeholder, expr_text} ->
            case parse(expr_text) do
              {:ok, ast} -> ast_step_refs(ast)
              _ -> []
            end

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp ast_step_refs({:member, {:identifier, "steps"}, step_id}), do: [step_id]
  defp ast_step_refs({:member, target, _}), do: ast_step_refs(target)
  defp ast_step_refs({:index, target, index}), do: ast_step_refs(target) ++ ast_step_refs(index)
  defp ast_step_refs({:not, ast}), do: ast_step_refs(ast)
  defp ast_step_refs({:bin_op, _, l, r}), do: ast_step_refs(l) ++ ast_step_refs(r)
  defp ast_step_refs({:format, ast, _}), do: ast_step_refs(ast)
  defp ast_step_refs(_), do: []
end

defmodule Condukt.Workflows.DSL do
  @moduledoc """
  Macro DSL for authoring `.exs` workflow files.

  The DSL builds the same workflow document accepted by
  `Condukt.Workflows.Document`, but lets workflow files read like a
  small declarative language:

      use Condukt.Workflows.DSL

      workflow "hello" do
        input :name, :string

        cmd :greet, ["echo", "Hello, \#{input(:name)}"]

        output step(:greet, :stdout)
      end

  The result of `workflow/2` is a plain map. JSON and YAML remain the
  interchange formats; `.exs` is the ergonomic authoring format.
  """

  @marker :__condukt_workflow_dsl__

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Condukt.Workflows.DSL
    end
  end

  @doc """
  Declares a workflow document.

  The block can contain DSL declarations plus ordinary Elixir used to
  build those declarations. Non-DSL expression results are evaluated
  and ignored, which allows variables, comprehensions, and conditionals
  to shape the generated document.
  """
  defmacro workflow(do: block) do
    workflow_quote(nil, block)
  end

  defmacro workflow(name, do: block) do
    workflow_quote(name, block)
  end

  defp workflow_quote(name, block) do
    items = block_items(block)
    {setup, declarations} = Enum.split_with(items, &setup_expression?/1)

    workflow =
      quote do
        Condukt.Workflows.DSL.__workflow__(unquote(name), [unquote_splicing(declarations)])
      end

    {:__block__, [], setup ++ [workflow]}
  end

  defp setup_expression?({:=, _meta, _args}), do: true
  defp setup_expression?({:defmodule, _meta, _args}), do: true
  defp setup_expression?({:alias, _meta, _args}), do: true
  defp setup_expression?({:import, _meta, _args}), do: true
  defp setup_expression?({:require, _meta, _args}), do: true
  defp setup_expression?(_expr), do: false

  @doc """
  Declares an input, or references an input inside an expression string.

      input :name, :string
      input :name, :string, description: "Person to greet"
      "Hello, \#{input(:name)}"
  """
  defmacro input(id) do
    quote do
      Condukt.Workflows.DSL.__input_ref__(unquote(id))
    end
  end

  defmacro input(id, type_or_opts) do
    quote do
      Condukt.Workflows.DSL.__input__(unquote(id), unquote(type_or_opts), [])
    end
  end

  defmacro input(id, type, opts) do
    quote do
      Condukt.Workflows.DSL.__input__(unquote(id), unquote(type), unquote(opts))
    end
  end

  @doc """
  Declares the workflow output.
  """
  defmacro output(value) do
    quote do
      Condukt.Workflows.DSL.__output__(unquote(value))
    end
  end

  @doc """
  Declares a command step.

      cmd :greet, ["echo", "Hello, \#{input(:name)}"]

  Inside a `map` block, omit the step id to produce the anonymous
  sub-step required by the workflow schema:

      cmd ["echo", item(:id)]
  """
  defmacro cmd(argv) do
    quote do
      Condukt.Workflows.DSL.__anonymous_step__(Condukt.Workflows.DSL.__cmd_step__(unquote(argv), []))
    end
  end

  defmacro cmd(first, second) do
    if list_ast?(first) and keyword_ast?(second) do
      quote do
        Condukt.Workflows.DSL.__anonymous_step__(Condukt.Workflows.DSL.__cmd_step__(unquote(first), unquote(second)))
      end
    else
      quote do
        Condukt.Workflows.DSL.__step__(
          unquote(first),
          Condukt.Workflows.DSL.__cmd_step__(unquote(second), [])
        )
      end
    end
  end

  defmacro cmd(id, argv, opts) do
    quote do
      Condukt.Workflows.DSL.__step__(
        unquote(id),
        Condukt.Workflows.DSL.__cmd_step__(unquote(argv), unquote(opts))
      )
    end
  end

  @doc """
  Declares an HTTP step.

      http :fetch, :get, "https://example.test/items", expect_status: 200
  """
  defmacro http(method, url) do
    quote do
      Condukt.Workflows.DSL.__anonymous_step__(Condukt.Workflows.DSL.__http_step__(unquote(method), unquote(url), []))
    end
  end

  defmacro http(first, second, third) do
    if keyword_ast?(third) do
      quote do
        Condukt.Workflows.DSL.__anonymous_step__(
          Condukt.Workflows.DSL.__http_step__(unquote(first), unquote(second), unquote(third))
        )
      end
    else
      quote do
        Condukt.Workflows.DSL.__step__(
          unquote(first),
          Condukt.Workflows.DSL.__http_step__(unquote(second), unquote(third), [])
        )
      end
    end
  end

  defmacro http(id, method, url, opts) do
    quote do
      Condukt.Workflows.DSL.__step__(
        unquote(id),
        Condukt.Workflows.DSL.__http_step__(unquote(method), unquote(url), unquote(opts))
      )
    end
  end

  @doc """
  Declares an agent step.

      agent :review, "claude-opus-4-7", input: step(:fetch, :body)
  """
  defmacro agent(model, opts) do
    quote do
      Condukt.Workflows.DSL.__anonymous_step__(Condukt.Workflows.DSL.__agent_step__(unquote(model), unquote(opts)))
    end
  end

  defmacro agent(id, model, opts) do
    quote do
      Condukt.Workflows.DSL.__step__(
        unquote(id),
        Condukt.Workflows.DSL.__agent_step__(unquote(model), unquote(opts))
      )
    end
  end

  @doc """
  Declares a tool step.

      tool :readme, "Read", args: %{file_path: "README.md"}
  """
  defmacro tool(tool_id) do
    quote do
      Condukt.Workflows.DSL.__anonymous_step__(Condukt.Workflows.DSL.__tool_step__(unquote(tool_id), []))
    end
  end

  defmacro tool(first, second) do
    if keyword_ast?(second) do
      quote do
        Condukt.Workflows.DSL.__anonymous_step__(Condukt.Workflows.DSL.__tool_step__(unquote(first), unquote(second)))
      end
    else
      quote do
        Condukt.Workflows.DSL.__step__(
          unquote(first),
          Condukt.Workflows.DSL.__tool_step__(unquote(second), [])
        )
      end
    end
  end

  defmacro tool(id, tool_id, opts) do
    quote do
      Condukt.Workflows.DSL.__step__(
        unquote(id),
        Condukt.Workflows.DSL.__tool_step__(unquote(tool_id), unquote(opts))
      )
    end
  end

  @doc """
  Declares a map step.

      map :echo_items, over: step(:fetch, :body, :items), as: :item do
        cmd ["echo", item(:id)]
      end
  """
  defmacro map(id, opts, do: block) do
    items = block_items(block)
    {setup, declarations} = Enum.split_with(items, &setup_expression?/1)

    map_step =
      quote do
        Condukt.Workflows.DSL.__step__(
          unquote(id),
          Condukt.Workflows.DSL.__map_step__(unquote(opts), [unquote_splicing(declarations)])
        )
      end

    {:__block__, [], setup ++ [map_step]}
  end

  @doc """
  Wraps a raw workflow expression.

      expr("inputs.enabled")
  """
  @spec expr(String.t()) :: String.t()
  def expr(expression) when is_binary(expression), do: "${#{expression}}"

  @doc """
  References a previous step output.

      step(:greet, :stdout)
      step(:fetch, :body, :items)
  """
  @spec step(atom() | String.t(), atom() | String.t(), [atom() | String.t()] | atom() | String.t()) ::
          String.t()
  def step(id, first_segment, rest_segments \\ []) do
    expression(["steps", id, first_segment | List.wrap(rest_segments)])
  end

  @doc """
  References a `map` binding named `item`.
  """
  @spec item(atom() | String.t(), [atom() | String.t()] | atom() | String.t()) :: String.t()
  def item(first_segment, rest_segments \\ []) do
    expression(["item", first_segment | List.wrap(rest_segments)])
  end

  @doc """
  References a binding introduced by a `map` step.
  """
  @spec var(atom() | String.t(), atom() | String.t(), [atom() | String.t()] | atom() | String.t()) ::
          String.t()
  def var(name, first_segment, rest_segments \\ []) do
    expression([name, first_segment | List.wrap(rest_segments)])
  end

  @doc """
  Applies the `:json` formatter to an expression reference.
  """
  @spec json(String.t()) :: String.t()
  def json(reference), do: format(reference, "json")

  @doc """
  Applies the `:csv` formatter to an expression reference.
  """
  @spec csv(String.t()) :: String.t()
  def csv(reference), do: format(reference, "csv")

  @doc false
  def __workflow__(name, values) do
    values
    |> collect_declarations()
    |> build_workflow(name)
  end

  @doc false
  def __input__(id, type_or_opts, opts) do
    {type, opts} = input_type_and_opts(type_or_opts, opts)
    declaration(:input, {id, Map.put(Map.new(opts), :type, type)})
  end

  @doc false
  def __input_ref__(id), do: expression(["inputs", id])

  @doc false
  def __output__(value), do: declaration(:output, value)

  @doc false
  def __step__(id, step), do: declaration(:step, {id, step})

  @doc false
  def __anonymous_step__(step), do: declaration(:anonymous_step, step)

  @doc false
  def __cmd_step__(argv, opts) when is_list(opts) do
    opts
    |> common_step_fields()
    |> Map.merge(%{kind: :cmd, argv: argv})
    |> maybe_put(:cwd, Keyword.get(opts, :cwd))
    |> maybe_put(:env, Keyword.get(opts, :env))
  end

  @doc false
  def __http_step__(method, url, opts) when is_list(opts) do
    opts
    |> common_step_fields()
    |> Map.merge(%{kind: :http, method: normalize_method(method), url: url})
    |> maybe_put(:headers, Keyword.get(opts, :headers))
    |> maybe_put(:body, Keyword.get(opts, :body))
    |> maybe_put(:expect_status, Keyword.get(opts, :expect_status))
  end

  @doc false
  def __agent_step__(model, opts) when is_list(opts) do
    opts
    |> common_step_fields()
    |> Map.merge(%{kind: :agent, model: model})
    |> maybe_put(:input, Keyword.fetch!(opts, :input))
    |> maybe_put(:tools, Keyword.get(opts, :tools))
    |> maybe_put(:system, Keyword.get(opts, :system))
    |> maybe_put(:output_schema, Keyword.get(opts, :output_schema))
  end

  @doc false
  def __tool_step__(tool_id, opts) when is_list(opts) do
    opts
    |> common_step_fields()
    |> Map.merge(%{kind: :tool, id: tool_id})
    |> maybe_put(:args, Keyword.get(opts, :args))
  end

  @doc false
  def __map_step__(opts, values) when is_list(opts) do
    substep =
      values
      |> collect_declarations()
      |> anonymous_substep!()

    opts
    |> common_step_fields()
    |> Map.merge(%{
      kind: :map,
      over: Keyword.fetch!(opts, :over),
      as: Keyword.fetch!(opts, :as),
      do: substep
    })
    |> maybe_put(:concurrency, Keyword.get(opts, :concurrency))
  end

  defp block_items({:__block__, _meta, items}), do: items
  defp block_items(item), do: [item]

  defp list_ast?(items) when is_list(items), do: true
  defp list_ast?(_other), do: false

  defp keyword_ast?(items) when is_list(items), do: Keyword.keyword?(items)
  defp keyword_ast?(_other), do: false

  defp declaration(type, payload), do: {@marker, type, payload}

  defp collect_declarations(values) when is_list(values) do
    Enum.flat_map(values, &collect_declarations/1)
  end

  defp collect_declarations({@marker, _type, _payload} = declaration), do: [declaration]
  defp collect_declarations(_other), do: []

  defp build_workflow(declarations, name) do
    base = %{steps: %{}}
    base = if is_nil(name), do: base, else: Map.put(base, :name, name)

    Enum.reduce(declarations, base, fn
      {@marker, :input, {id, schema}}, acc ->
        inputs = Map.put(Map.get(acc, :inputs, %{}), id, schema)
        Map.put(acc, :inputs, inputs)

      {@marker, :step, {id, step}}, acc ->
        Map.update!(acc, :steps, &Map.put(&1, id, step))

      {@marker, :output, value}, acc ->
        Map.put(acc, :output, value)

      {@marker, :anonymous_step, _step}, _acc ->
        raise ArgumentError, "anonymous workflow steps are only valid inside map blocks"
    end)
  end

  defp anonymous_substep!([{@marker, :anonymous_step, step}]), do: step

  defp anonymous_substep!([]) do
    raise ArgumentError, "map blocks must contain one anonymous sub-step"
  end

  defp anonymous_substep!(_declarations) do
    raise ArgumentError, "map blocks must contain exactly one anonymous sub-step"
  end

  defp input_type_and_opts(type_or_opts, []) when is_list(type_or_opts) do
    {Keyword.fetch!(type_or_opts, :type), Keyword.delete(type_or_opts, :type)}
  end

  defp input_type_and_opts(type, opts), do: {type, opts}

  defp common_step_fields(opts) do
    %{}
    |> maybe_put(:needs, Keyword.get(opts, :needs))
    |> maybe_put(:when, Keyword.get(opts, :when))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_method(method) when is_atom(method) do
    method
    |> Atom.to_string()
    |> String.upcase()
  end

  defp normalize_method(method) when is_binary(method), do: String.upcase(method)

  defp expression(segments) do
    path =
      segments
      |> List.flatten()
      |> Enum.map_join(".", &to_string/1)

    expr(path)
  end

  defp format("${" <> rest, formatter) do
    case String.split(rest, "}", parts: 2) do
      [expression, ""] -> "${#{expression}:#{formatter}}"
      _other -> raise ArgumentError, "formatters require a single expression reference"
    end
  end

  defp format(_reference, _formatter) do
    raise ArgumentError, "formatters require a single expression reference"
  end
end

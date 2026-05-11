defmodule Condukt.Workflows.Validator do
  @moduledoc false

  @name_pattern ~r/^[a-zA-Z][a-zA-Z0-9_-]*$/
  @step_id_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
  @input_types ~w(string integer number boolean array object)
  @runtime_sandboxes ~w(local virtual)
  @step_kinds ~w(cmd agent http tool map)
  @http_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)

  @top_level_keys ~w(name inputs runtime mcp_servers steps output)
  @input_keys ~w(type description default enum items)
  @runtime_keys ~w(model sandbox cwd)
  @mcp_server_keys ~w(transport command args env url headers auth prefix init_timeout request_timeout)
  @mcp_transports ~w(stdio http http_sse streamable_http)
  @common_step_keys ~w(kind needs when)
  @step_keys %{
    "cmd" => @common_step_keys ++ ~w(argv cwd env),
    "agent" => @common_step_keys ++ ~w(model input tools system output_schema),
    "http" => @common_step_keys ++ ~w(method url headers body expect_status),
    "tool" => @common_step_keys ++ ~w(id args),
    "map" => @common_step_keys ++ ~w(over as do concurrency)
  }

  def validate(%{} = doc) do
    with :ok <- known_keys(doc, @top_level_keys, [:workflow]),
         :ok <- optional_string(doc, "name", [:workflow, "name"]),
         :ok <- valid_name(doc),
         :ok <- optional_map(doc, "inputs", [:workflow, "inputs"]),
         :ok <- optional_map(doc, "runtime", [:workflow, "runtime"]),
         :ok <- optional_map(doc, "mcp_servers", [:workflow, "mcp_servers"]),
         :ok <- required_map(doc, "steps", [:workflow, "steps"]),
         :ok <- validate_inputs(Map.get(doc, "inputs", %{})),
         :ok <- validate_runtime(Map.get(doc, "runtime", %{})),
         :ok <- validate_mcp_servers(Map.get(doc, "mcp_servers", %{})),
         :ok <- validate_steps(Map.fetch!(doc, "steps")) do
      {:ok, doc}
    end
  end

  def validate(other), do: {:error, {:expected_map, [:workflow], other}}

  defp validate_inputs(inputs) do
    Enum.reduce_while(inputs, :ok, fn {id, spec}, :ok ->
      case validate_input_spec(id, spec) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_input_spec(id, spec) when is_binary(id) and is_map(spec) do
    path = [:workflow, "inputs", id]

    with :ok <- known_keys(spec, @input_keys, path),
         :ok <- required_string(spec, "type", path ++ ["type"]),
         :ok <- one_of(spec["type"], @input_types, path ++ ["type"]),
         :ok <- optional_string(spec, "description", path ++ ["description"]),
         :ok <- optional_list(spec, "enum", path ++ ["enum"]) do
      optional_map(spec, "items", path ++ ["items"])
    end
  end

  defp validate_input_spec(id, _spec), do: {:error, {:invalid_input, [:workflow, "inputs", id]}}

  defp validate_mcp_servers(servers) do
    Enum.reduce_while(servers, :ok, fn {id, spec}, :ok ->
      case validate_mcp_server(id, spec) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_mcp_server(id, spec) when is_binary(id) and is_map(spec) do
    path = [:workflow, "mcp_servers", id]

    with :ok <- valid_mcp_server_id(id, path),
         :ok <- known_keys(spec, @mcp_server_keys, path),
         :ok <- required_string(spec, "transport", path ++ ["transport"]),
         :ok <- one_of(spec["transport"], @mcp_transports, path ++ ["transport"]) do
      validate_mcp_transport_attrs(spec["transport"], spec, path)
    end
  end

  defp validate_mcp_server(id, _spec), do: {:error, {:invalid_mcp_server, [:workflow, "mcp_servers", id]}}

  defp valid_mcp_server_id(id, path) do
    if Regex.match?(@name_pattern, id), do: :ok, else: {:error, {:invalid_mcp_server_id, path, id}}
  end

  defp validate_mcp_transport_attrs("stdio", spec, path) do
    with :ok <- required_string(spec, "command", path ++ ["command"]) do
      optional_list(spec, "args", path ++ ["args"])
    end
  end

  defp validate_mcp_transport_attrs(transport, spec, path) when transport in ["http", "http_sse", "streamable_http"] do
    required_string(spec, "url", path ++ ["url"])
  end

  defp validate_runtime(runtime) do
    with :ok <- known_keys(runtime, @runtime_keys, [:workflow, "runtime"]),
         :ok <- optional_model(runtime, "model", [:workflow, "runtime", "model"]),
         :ok <- optional_string(runtime, "sandbox", [:workflow, "runtime", "sandbox"]),
         :ok <- optional_string(runtime, "cwd", [:workflow, "runtime", "cwd"]) do
      maybe_one_of(runtime, "sandbox", @runtime_sandboxes, [:workflow, "runtime", "sandbox"])
    end
  end

  defp validate_steps(steps) when map_size(steps) > 0 do
    Enum.reduce_while(steps, :ok, &validate_step_entry/2)
  end

  defp validate_steps(%{}), do: {:error, {:empty_steps, [:workflow, "steps"]}}

  defp validate_step_entry({id, step}, :ok) do
    case validate_step_id(id, [:workflow, "steps"]) do
      :ok -> continue_or_halt(validate_step(step, [:workflow, "steps", id]))
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_step(step, path) when is_map(step) do
    with :ok <- required_string(step, "kind", path ++ ["kind"]),
         :ok <- one_of(step["kind"], @step_kinds, path ++ ["kind"]),
         kind = step["kind"],
         :ok <- known_keys(step, Map.fetch!(@step_keys, kind), path),
         :ok <- validate_common_step(step, path) do
      validate_specific_step(kind, step, path)
    end
  end

  defp validate_step(other, path), do: {:error, {:expected_map, path, other}}

  defp validate_common_step(step, path) do
    with :ok <- optional_string(step, "when", path ++ ["when"]) do
      validate_needs(Map.get(step, "needs"), path ++ ["needs"])
    end
  end

  defp validate_needs(nil, _path), do: :ok

  defp validate_needs(needs, path) when is_list(needs) do
    with :ok <- unique_list(needs, path) do
      validate_step_ids(needs, path)
    end
  end

  defp validate_needs(other, path), do: {:error, {:expected_list, path, other}}

  defp validate_step_ids(ids, path) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      continue_or_halt(validate_step_id(id, path))
    end)
  end

  defp validate_specific_step("cmd", step, path) do
    with :ok <- required_list(step, "argv", path ++ ["argv"]),
         :ok <- non_empty_list(step["argv"], path ++ ["argv"]),
         :ok <- list_of_strings(step["argv"], path ++ ["argv"]),
         :ok <- optional_string(step, "cwd", path ++ ["cwd"]) do
      optional_string_map(step, "env", path ++ ["env"])
    end
  end

  defp validate_specific_step("agent", step, path) do
    with :ok <- required_key(step, "input", path ++ ["input"]),
         :ok <- optional_string(step, "model", path ++ ["model"]),
         :ok <- optional_string(step, "system", path ++ ["system"]),
         :ok <- optional_map(step, "output_schema", path ++ ["output_schema"]) do
      optional_unique_string_list(step, "tools", path ++ ["tools"])
    end
  end

  defp validate_specific_step("http", step, path) do
    with :ok <- required_string(step, "method", path ++ ["method"]),
         :ok <- one_of(step["method"], @http_methods, path ++ ["method"]),
         :ok <- required_string(step, "url", path ++ ["url"]),
         :ok <- optional_string_map(step, "headers", path ++ ["headers"]) do
      optional_expect_status(step, "expect_status", path ++ ["expect_status"])
    end
  end

  defp validate_specific_step("tool", step, path) do
    with :ok <- required_string(step, "id", path ++ ["id"]) do
      optional_map(step, "args", path ++ ["args"])
    end
  end

  defp validate_specific_step("map", step, path) do
    with :ok <- required_string(step, "over", path ++ ["over"]),
         :ok <- required_string(step, "as", path ++ ["as"]),
         :ok <- validate_step_id(step["as"], path ++ ["as"]),
         :ok <- required_map(step, "do", path ++ ["do"]),
         :ok <- validate_step(step["do"], path ++ ["do"]) do
      optional_positive_integer(step, "concurrency", path ++ ["concurrency"])
    end
  end

  defp valid_name(%{"name" => name}), do: validate_name(name, [:workflow, "name"])
  defp valid_name(_doc), do: :ok

  defp validate_name(name, path) when is_binary(name) do
    if Regex.match?(@name_pattern, name), do: :ok, else: {:error, {:invalid_name, path, name}}
  end

  defp validate_name(other, path), do: {:error, {:expected_string, path, other}}

  defp validate_step_id(id, path) when is_binary(id) do
    if Regex.match?(@step_id_pattern, id), do: :ok, else: {:error, {:invalid_step_id, path, id}}
  end

  defp validate_step_id(other, path), do: {:error, {:expected_string, path, other}}

  defp known_keys(map, allowed, path) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      keys -> {:error, {:unknown_keys, path, Enum.sort(keys)}}
    end
  end

  defp required_key(map, key, path) do
    if Map.has_key?(map, key), do: :ok, else: {:error, {:missing_key, path}}
  end

  defp required_string(map, key, path) do
    with :ok <- required_key(map, key, path) do
      optional_string(map, key, path)
    end
  end

  defp optional_string(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> :ok
      {:ok, value} -> {:error, {:expected_string, path, value}}
      :error -> :ok
    end
  end

  defp required_map(map, key, path) do
    with :ok <- required_key(map, key, path) do
      optional_map(map, key, path)
    end
  end

  defp optional_map(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> :ok
      {:ok, value} -> {:error, {:expected_map, path, value}}
      :error -> :ok
    end
  end

  defp required_list(map, key, path) do
    with :ok <- required_key(map, key, path) do
      optional_list(map, key, path)
    end
  end

  defp optional_list(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> :ok
      {:ok, value} -> {:error, {:expected_list, path, value}}
      :error -> :ok
    end
  end

  defp optional_model(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) or is_map(value) -> :ok
      {:ok, value} -> {:error, {:expected_model, path, value}}
      :error -> :ok
    end
  end

  defp maybe_one_of(map, key, allowed, path) do
    case Map.fetch(map, key) do
      {:ok, value} -> one_of(value, allowed, path)
      :error -> :ok
    end
  end

  defp one_of(value, allowed, path) do
    if value in allowed, do: :ok, else: {:error, {:invalid_value, path, value, allowed}}
  end

  defp non_empty_list([], path), do: {:error, {:empty_list, path}}
  defp non_empty_list(list, _path) when is_list(list), do: :ok

  defp list_of_strings(list, path) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      if is_binary(value), do: {:cont, :ok}, else: {:halt, {:error, {:expected_string, path ++ [index], value}}}
    end)
  end

  defp optional_unique_string_list(map, key, path) do
    with :ok <- optional_list(map, key, path) do
      validate_optional_string_list(Map.fetch(map, key), path)
    end
  end

  defp validate_optional_string_list({:ok, list}, path) do
    with :ok <- unique_list(list, path) do
      list_of_strings(list, path)
    end
  end

  defp validate_optional_string_list(:error, _path), do: :ok

  defp optional_string_map(map, key, path) do
    with :ok <- optional_map(map, key, path) do
      case Map.fetch(map, key) do
        {:ok, value} -> string_map(value, path)
        :error -> :ok
      end
    end
  end

  defp string_map(map, path) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      cond do
        not is_binary(key) -> {:halt, {:error, {:expected_string_key, path, key}}}
        not is_binary(value) -> {:halt, {:error, {:expected_string, path ++ [key], value}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp unique_list(list, path) do
    if Enum.uniq(list) == list, do: :ok, else: {:error, {:duplicate_values, path}}
  end

  defp optional_expect_status(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} -> validate_expect_status(value, path)
      :error -> :ok
    end
  end

  defp validate_expect_status(value, _path) when is_integer(value), do: :ok

  defp validate_expect_status(value, path) when is_list(value) do
    Enum.reduce_while(value, :ok, fn status, :ok ->
      if is_integer(status), do: {:cont, :ok}, else: {:halt, {:error, {:expected_integer, path, status}}}
    end)
  end

  defp validate_expect_status(value, path), do: {:error, {:expected_integer_or_integer_list, path, value}}

  defp optional_positive_integer(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 1 -> :ok
      {:ok, value} -> {:error, {:expected_positive_integer, path, value}}
      :error -> :ok
    end
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, reason}), do: {:halt, {:error, reason}}
end

defmodule Condukt.Plug do
  @moduledoc """
  Exposes Condukt agents and typed operations as HTTP routes.

  `Condukt.Plug` is a regular Plug that runs either a statically declared
  `Condukt.Operation` or a module-defined one-shot agent.

      post "/review-pr",
        to: Condukt.Plug,
        init_opts: [
          agent: MyApp.ReviewAgent,
          operation: :review_pr,
          run_opts: [timeout: 120_000]
        ]

  Agent routes omit `:operation`. The request body can include an optional
  `"prompt"` string. If no prompt is provided, `:prompt` is used, falling back
  to an empty prompt.

      post "/assistant",
        to: Condukt.Plug,
        init_opts: [
          agent: MyApp.AssistantAgent,
          prompt: "Help with this request.",
          run_opts: [timeout: 120_000]
        ]

  For terser Plug router declarations, import the route helpers:

      import Condukt.Plug, only: [agent_route: 2, agent_route: 3, operation_route: 3, operation_route: 4]

      agent_route "/assistant", MyApp.AssistantAgent, prompt: "Help with this request."
      operation_route "/review-pr", MyApp.ReviewAgent, :review_pr

  The request body must be a JSON object. Operation routes use the object as
  operation input. Agent routes read the optional prompt from the `"prompt"`
  field by default. If `Plug.Parsers` has already parsed the body,
  `conn.body_params` is reused. Otherwise this plug reads and decodes the JSON
  body itself.

  Successful responses are encoded as:

      {"ok": true, "result": {...}}

  Error responses are encoded as:

      {"ok": false, "error": {"code": "invalid_input", "message": "..."}}
  """

  @type opts :: [
          agent: module(),
          operation: atom(),
          prompt: String.t() | (Plug.Conn.t() -> String.t()),
          prompt_param: String.t() | atom(),
          run_opts: keyword() | (Plug.Conn.t() -> keyword()),
          input: (Plug.Conn.t() -> map())
        ]

  @doc """
  Declares a POST route for an operation.

  This macro expands to Plug Router's `post/3` target plug form. Phoenix
  routers can use `Condukt.Phoenix.operation_route/3` instead.
  """
  defmacro operation_route(path, agent_module, operation_name, opts \\ []) do
    plug_opts =
      opts
      |> Keyword.put(:operation, operation_name)
      |> Keyword.put(:agent, agent_module)

    quote do
      post(unquote(path), to: Condukt.Plug, init_opts: unquote(plug_opts))
    end
  end

  @doc """
  Declares a POST route for a module-defined one-shot agent.

  This macro expands to Plug Router's `post/3` target plug form. Phoenix
  routers can use `Condukt.Phoenix.agent_route/2` instead.
  """
  defmacro agent_route(path, agent_module, opts \\ []) do
    plug_opts = Keyword.put(opts, :agent, agent_module)

    quote do
      post(unquote(path), to: Condukt.Plug, init_opts: unquote(plug_opts))
    end
  end

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, opts) do
    case required_opt(opts, :agent) do
      {:ok, agent_module} ->
        dispatch(conn, opts, agent_module)

      {:error, reason} ->
        {status, code, message} = error_response(reason)
        json(conn, status, %{ok: false, error: %{code: code, message: message}})
    end
  end

  defp dispatch(conn, opts, agent_module) do
    case Keyword.fetch(opts, :operation) do
      {:ok, operation_name} -> run_operation(conn, opts, agent_module, operation_name)
      :error -> run_agent(conn, opts, agent_module)
    end
  end

  defp run_operation(conn, opts, agent_module, operation_name) do
    with {:ok, input} <- input(conn, opts),
         {:ok, result} <- Condukt.Operation.run(agent_module, operation_name, input, run_opts(opts, conn)) do
      json(conn, 200, %{ok: true, result: result})
    else
      {:error, reason} ->
        {status, code, message} = error_response(reason)
        json(conn, status, %{ok: false, error: %{code: code, message: message}})
    end
  end

  defp run_agent(conn, opts, agent_module) do
    with {:ok, params} <- body_input(conn),
         {:ok, prompt} <- prompt(conn, opts, params),
         {:ok, result} <- Condukt.run(agent_module, prompt, run_opts(opts, conn)) do
      json(conn, 200, %{ok: true, result: result})
    else
      {:error, reason} ->
        {status, code, message} = error_response(reason)
        json(conn, status, %{ok: false, error: %{code: code, message: message}})
    end
  end

  defp required_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp input(conn, opts) do
    case Keyword.get(opts, :input) do
      input_fun when is_function(input_fun, 1) -> normalize_input(input_fun.(conn))
      nil -> body_input(conn)
    end
  end

  defp normalize_input(input) when is_map(input), do: {:ok, input}
  defp normalize_input(_input), do: {:error, :input_must_be_a_map}

  defp prompt(conn, opts, params) do
    prompt_key = Keyword.get(opts, :prompt_param, "prompt")

    case fetch_param(params, prompt_key) do
      {:ok, prompt} -> validate_prompt(prompt)
      :error -> route_prompt(conn, opts)
    end
  end

  defp fetch_param(params, key) when is_atom(key) do
    case Map.fetch(params, Atom.to_string(key)) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(params, key)
    end
  end

  defp fetch_param(params, key) when is_binary(key) do
    Map.fetch(params, key)
  end

  defp route_prompt(conn, opts) do
    case Keyword.get(opts, :prompt, "") do
      prompt_fun when is_function(prompt_fun, 1) -> validate_prompt(prompt_fun.(conn))
      prompt -> validate_prompt(prompt)
    end
  end

  defp validate_prompt(prompt) when is_binary(prompt), do: {:ok, prompt}
  defp validate_prompt(_prompt), do: {:error, :prompt_must_be_a_string}

  defp body_input(conn) do
    case body_params(conn) do
      {:ok, params} -> normalize_input(params)
      :unfetched -> read_json_body(conn)
    end
  end

  defp body_params(conn) do
    case Map.fetch(conn, :body_params) do
      {:ok, %{__struct__: Plug.Conn.Unfetched}} -> :unfetched
      {:ok, params} -> {:ok, params}
      :error -> :unfetched
    end
  end

  defp read_json_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", _conn} -> {:ok, %{}}
      {:ok, body, _conn} -> decode_json(body)
      {:more, _partial, _conn} -> {:error, :body_too_large}
      {:error, reason} -> {:error, {:body_read_failed, reason}}
    end
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :json_body_must_be_an_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp run_opts(opts, conn) do
    case Keyword.get(opts, :run_opts, []) do
      fun when is_function(fun, 1) -> fun.(conn)
      run_opts when is_list(run_opts) -> run_opts
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
    |> Plug.Conn.halt()
  end

  defp error_response({:missing_option, key}) do
    {500, "missing_option", "Missing required Condukt.Plug option #{inspect(key)}."}
  end

  defp error_response({:unknown_operation, operation_name}) do
    {404, "unknown_operation", "Unknown operation #{inspect(operation_name)}."}
  end

  defp error_response({:invalid_input, reason}) do
    {422, "invalid_input", validation_message(reason)}
  end

  defp error_response({:invalid_output, reason}) do
    {502, "invalid_output", validation_message(reason)}
  end

  defp error_response({:invalid_json, reason}) do
    {400, "invalid_json", "Request body is not valid JSON: #{inspect(reason)}."}
  end

  defp error_response(:json_body_must_be_an_object) do
    {400, "invalid_json", "Request body must be a JSON object."}
  end

  defp error_response(:input_must_be_a_map) do
    {400, "invalid_input", "Route input must be a map."}
  end

  defp error_response(:prompt_must_be_a_string) do
    {400, "invalid_prompt", "Route prompt must be a string."}
  end

  defp error_response(:body_too_large) do
    {413, "body_too_large", "Request body is too large."}
  end

  defp error_response({:body_read_failed, reason}) do
    {400, "body_read_failed", "Could not read request body: #{inspect(reason)}."}
  end

  defp error_response(:no_result_submitted) do
    {502, "no_result_submitted", "The agent finished without submitting a structured result."}
  end

  defp error_response(reason) do
    {500, "operation_failed", inspect(reason)}
  end

  defp validation_message(%JSV.ValidationError{} = error), do: Exception.message(error)
  defp validation_message(reason), do: inspect(reason)
end

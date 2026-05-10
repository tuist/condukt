defmodule Condukt.MCP.Server do
  @moduledoc """
  Declarative configuration for a connected MCP server.

  See `Condukt.MCP` for the supported transports, authentication shapes,
  and how the struct fits into agents and workflows.

  ## Fields

    * `:name` (required, string) - identifier used to prefix tools
      discovered on this server (`<name>.<tool>` unless overridden by
      `:prefix`). Must match `~r/^[A-Za-z][A-Za-z0-9_-]*$/`.

    * `:transport` (required) - one of:
      - `{:stdio, command: binary, args: [binary], env: %{string => string}}` -
        spawns a subprocess and exchanges newline-delimited JSON-RPC over
        its stdio.
      - `{:http_sse, url: binary, headers: %{string => string}}` - the
        legacy 2024-11 transport with separate POST and SSE endpoints.
      - `{:streamable_http, url: binary, headers: %{string => string}}` -
        the 2025-03-26 single-URL streamable HTTP transport. Default for
        new HTTP-based MCP servers.

    * `:auth` - HTTP authentication. See `Condukt.MCP` for the supported
      shapes. Ignored by the stdio transport.

    * `:env` - extra environment variables to inject into the spawned
      subprocess (stdio only). May be a list of variable names to
      passthrough from the parent process (`["GITHUB_TOKEN"]`) or a map
      of names to secret refs (`%{"GH_TOKEN" => {:env, "GITHUB_TOKEN"}}`).

    * `:prefix` - overrides the default `<name>.` tool name prefix. Pass
      `""` to expose tools without any prefix (use with care, server
      names then become irrelevant for collision avoidance).

    * `:init_timeout` - max milliseconds to wait for the `initialize`
      handshake and `tools/list` exchange (default `10_000`).

    * `:request_timeout` - max milliseconds for a single tool call
      (default `60_000`).
  """

  @enforce_keys [:name, :transport]
  defstruct [
    :name,
    :transport,
    :auth,
    :env,
    :prefix,
    init_timeout: 10_000,
    request_timeout: 60_000
  ]

  @type transport ::
          {:stdio, keyword()}
          | {:http_sse, keyword()}
          | {:streamable_http, keyword()}

  @type secret_ref ::
          {:env, String.t()}
          | {:static, String.t()}
          | {atom(), term()}
          | {module(), keyword()}

  @type auth ::
          nil
          | {:bearer, secret_ref()}
          | {:client_credentials, keyword()}

  @type t :: %__MODULE__{
          name: String.t(),
          transport: transport(),
          auth: auth(),
          env: nil | [String.t()] | %{String.t() => secret_ref() | String.t()},
          prefix: nil | String.t(),
          init_timeout: pos_integer(),
          request_timeout: pos_integer()
        }

  @name_pattern ~r/^[A-Za-z][A-Za-z0-9_-]*$/

  @doc """
  Returns the tool name prefix used for tools discovered on this server.
  """
  def prefix(%__MODULE__{prefix: nil, name: name}), do: name
  def prefix(%__MODULE__{prefix: prefix}), do: prefix

  @doc """
  Validates a server spec and normalizes shorthand fields.

  Returns `{:ok, server}` or `{:error, reason}`.
  """
  def normalize(%__MODULE__{} = server) do
    with :ok <- validate_name(server.name),
         {:ok, transport} <- normalize_transport(server.transport),
         :ok <- validate_auth(server.auth) do
      {:ok, %{server | transport: transport}}
    end
  end

  def normalize(map) when is_map(map) do
    map
    |> from_map()
    |> case do
      {:ok, server} -> normalize(server)
      {:error, _} = err -> err
    end
  end

  @doc false
  def from_map(%{} = map) do
    name = fetch_string(map, "name") || fetch_string(map, :name)
    transport = fetch(map, "transport") || fetch(map, :transport)

    cond do
      is_nil(name) ->
        {:error, :missing_name}

      is_nil(transport) ->
        {:error, :missing_transport}

      true ->
        with {:ok, transport} <- transport_from_map(transport, map) do
          server = %__MODULE__{
            name: name,
            transport: transport,
            auth: auth_from_map(fetch(map, "auth") || fetch(map, :auth)),
            env: fetch(map, "env") || fetch(map, :env),
            prefix: fetch(map, "prefix") || fetch(map, :prefix),
            init_timeout: fetch(map, "init_timeout") || fetch(map, :init_timeout) || 10_000,
            request_timeout: fetch(map, "request_timeout") || fetch(map, :request_timeout) || 60_000
          }

          {:ok, server}
        end
    end
  end

  defp fetch(map, key), do: Map.get(map, key)

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp transport_from_map({_kind, _opts} = transport, _map), do: {:ok, transport}
  defp transport_from_map("stdio", map), do: {:ok, {:stdio, stdio_opts(map)}}
  defp transport_from_map("http_sse", map), do: {:ok, {:http_sse, http_opts(map)}}
  defp transport_from_map("http", map), do: {:ok, {:streamable_http, http_opts(map)}}
  defp transport_from_map("streamable_http", map), do: {:ok, {:streamable_http, http_opts(map)}}
  defp transport_from_map(other, _map), do: {:error, {:invalid_transport, other}}

  defp stdio_opts(map) do
    [
      command: fetch(map, "command") || fetch(map, :command),
      args: fetch(map, "args") || fetch(map, :args) || []
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp http_opts(map) do
    [
      url: fetch(map, "url") || fetch(map, :url),
      headers: fetch(map, "headers") || fetch(map, :headers) || %{}
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp auth_from_map(nil), do: nil
  defp auth_from_map(%{"type" => "bearer"} = map), do: {:bearer, secret_ref_from_map(map)}
  defp auth_from_map(%{type: "bearer"} = map), do: {:bearer, secret_ref_from_map(map)}

  defp auth_from_map(%{"type" => "client_credentials"} = map), do: {:client_credentials, client_credentials_opts(map)}

  defp auth_from_map(%{type: "client_credentials"} = map), do: {:client_credentials, client_credentials_opts(map)}

  defp auth_from_map(other), do: other

  defp secret_ref_from_map(map) do
    cond do
      value = Map.get(map, "env") || Map.get(map, :env) -> {:env, value}
      value = Map.get(map, "static") || Map.get(map, :static) -> {:static, value}
      value = Map.get(map, "op") || Map.get(map, :op) -> {:op, value}
      true -> nil
    end
  end

  defp client_credentials_opts(map) do
    map
    |> Enum.flat_map(fn {k, v} ->
      key =
        case k do
          atom when is_atom(atom) -> atom
          binary when is_binary(binary) -> String.to_atom(binary)
        end

      if key == :type, do: [], else: [{key, v}]
    end)
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name), do: :ok, else: {:error, {:invalid_server_name, name}}
  end

  defp validate_name(other), do: {:error, {:invalid_server_name, other}}

  defp normalize_transport({:stdio, opts}) when is_list(opts) do
    case Keyword.get(opts, :command) do
      command when is_binary(command) and command != "" ->
        {:ok, {:stdio, opts}}

      _ ->
        {:error, :stdio_command_required}
    end
  end

  defp normalize_transport({kind, opts}) when kind in [:http_sse, :streamable_http] and is_list(opts) do
    case Keyword.get(opts, :url) do
      url when is_binary(url) and url != "" ->
        {:ok, {kind, opts}}

      _ ->
        {:error, {:url_required, kind}}
    end
  end

  defp normalize_transport(other), do: {:error, {:invalid_transport, other}}

  defp validate_auth(nil), do: :ok
  defp validate_auth({:bearer, _ref}), do: :ok
  defp validate_auth({:client_credentials, opts}) when is_list(opts), do: :ok
  defp validate_auth(other), do: {:error, {:invalid_auth, other}}
end

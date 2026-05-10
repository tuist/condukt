defmodule Condukt.MCP.Tool do
  @moduledoc false

  # Builds `Condukt.Tool.Inline` specs that wrap MCP tool descriptors.
  # The inline `:call` closure captures the client pid plus the
  # remote tool name and dispatches calls through `Condukt.MCP.Client`.

  alias Condukt.MCP.{Client, Server}
  alias Condukt.Tool.Inline

  @default_input_schema %{"type" => "object", "properties" => %{}}

  @doc """
  Returns the inline tool specs for every tool exposed by `client`,
  prefixed according to the server spec.
  """
  def inline_tools(client, %Server{} = server) when is_pid(client) do
    descriptors = Client.tools(client)
    prefix = Server.prefix(server)
    Enum.map(descriptors, &inline_for(client, server, prefix, &1))
  end

  defp inline_for(client, server, prefix, %{"name" => name} = descriptor) do
    %Inline{
      name: full_name(prefix, name),
      description: Map.get(descriptor, "description", ""),
      parameters: Map.get(descriptor, "inputSchema", @default_input_schema),
      call: fn args, _ctx ->
        Client.call_tool(client, name, args, timeout: server.request_timeout)
      end
    }
  end

  defp full_name(nil, name), do: name
  defp full_name("", name), do: name
  defp full_name(prefix, name), do: prefix <> "." <> name
end

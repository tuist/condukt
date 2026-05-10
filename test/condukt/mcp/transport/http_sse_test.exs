defmodule Condukt.MCP.Transport.HttpSSETest do
  use ExUnit.Case, async: true

  alias Condukt.MCP.{Client, Server}

  test "uses the injected POST request function for legacy HTTP+SSE messages" do
    test_pid = self()
    {:ok, coordinator} = Agent.start_link(fn -> nil end)

    sse_request = fn transport, _url, _headers, _opts ->
      Agent.update(coordinator, fn _ -> transport end)
      send(transport, {:sse_chunk, "event: endpoint\ndata: http://127.0.0.1:9/messages\n\n"})
      Process.sleep(:infinity)
    end

    http_request = fn _url, envelope, _headers ->
      send(test_pid, {:legacy_post, envelope})
      transport = wait_for_transport(coordinator)

      case envelope do
        %{"id" => id, "method" => "initialize"} ->
          send(transport, {:sse_chunk, sse_response(id, initialize_result())})
          {:ok, 202}

        %{"id" => id, "method" => "tools/list"} ->
          send(transport, {:sse_chunk, sse_response(id, tools_result())})
          {:ok, 202}

        %{"method" => "notifications/initialized"} ->
          {:ok, 202}
      end
    end

    server = %Server{
      name: "legacy",
      transport: {:http_sse, url: "http://127.0.0.1:9/sse"},
      init_timeout: 500
    }

    assert {:ok, client} = Client.start_link(server, sse_request: sse_request, http_request: http_request)
    assert [%{"name" => "echo"}] = Client.tools(client)
    assert_received {:legacy_post, %{"method" => "initialize"}}
    assert_received {:legacy_post, %{"method" => "tools/list"}}

    Client.stop(client)
  end

  defp wait_for_transport(coordinator) do
    case Agent.get(coordinator, & &1) do
      nil ->
        Process.sleep(10)
        wait_for_transport(coordinator)

      transport ->
        transport
    end
  end

  defp initialize_result do
    %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{},
      "serverInfo" => %{"name" => "legacy", "version" => "1.0"}
    }
  end

  defp tools_result do
    %{
      "tools" => [
        %{
          "name" => "echo",
          "description" => "Echoes a value.",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }
  end

  defp sse_response(id, result) do
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    "event: message\ndata: #{body}\n\n"
  end
end

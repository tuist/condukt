defmodule Condukt.Workflows.MCPWorkflowTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows
  alias Condukt.Workflows.{Document, HCLCompiler}

  @echo_script Path.expand("../../support/fixtures/mcp/echo_server.exs", __DIR__)

  describe "HCL compiler" do
    test "compiles an mcp_server block at the workflow level" do
      source = """
      workflow "with_mcp" {
        mcp_server "github" {
          transport = "stdio"
          command   = "github-mcp-server"
          args      = ["--verbose"]
          env       = ["GITHUB_TOKEN"]
        }

        cmd "noop" {
          argv = ["true"]
        }
      }
      """

      assert {:ok, decoded} = HCLCompiler.compile_string(source)
      assert decoded["mcp_servers"]["github"]["transport"] == "stdio"
      assert decoded["mcp_servers"]["github"]["command"] == "github-mcp-server"
      assert decoded["mcp_servers"]["github"]["env"] == ["GITHUB_TOKEN"]
    end

    test "compiles streamable_http with bearer auth" do
      source = """
      workflow "with_mcp" {
        mcp_server "linear" {
          transport = "streamable_http"
          url       = "https://mcp.linear.app/mcp"
          auth      = { type = "bearer", env = "LINEAR_API_KEY" }
        }

        cmd "noop" {
          argv = ["true"]
        }
      }
      """

      assert {:ok, decoded} = HCLCompiler.compile_string(source)
      assert decoded["mcp_servers"]["linear"]["auth"]["type"] == "bearer"
      assert decoded["mcp_servers"]["linear"]["auth"]["env"] == "LINEAR_API_KEY"
    end

    test "rejects an mcp_server with an unknown attribute" do
      source = """
      workflow "bad" {
        mcp_server "x" {
          transport = "stdio"
          command   = "x"
          bogus     = true
        }
      }
      """

      assert {:error, {:unknown_mcp_server_attr, _, _, ["bogus"]}} = HCLCompiler.compile_string(source)
    end

    test "rejects a duplicate mcp_server" do
      source = """
      workflow "bad" {
        mcp_server "x" { transport = "stdio" command = "x" }
        mcp_server "x" { transport = "stdio" command = "x" }
      }
      """

      assert {:error, {:duplicate_mcp_server, _, "x"}} = HCLCompiler.compile_string(source)
    end
  end

  describe "validator" do
    test "rejects an mcp_servers entry without a transport" do
      assert {:error, {:invalid_workflow, {:missing_key, [:workflow, "mcp_servers", "x", "transport"]}}} =
               Document.from_map(%{
                 "mcp_servers" => %{"x" => %{}},
                 "steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}}
               })
    end

    test "rejects an unknown transport" do
      assert {:error, {:invalid_workflow, {:invalid_value, [:workflow, "mcp_servers", "x", "transport"], "wat", _}}} =
               Document.from_map(%{
                 "mcp_servers" => %{"x" => %{"transport" => "wat"}},
                 "steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}}
               })
    end

    test "rejects a stdio mcp_server without a command" do
      assert {:error, {:invalid_workflow, {:missing_key, [:workflow, "mcp_servers", "x", "command"]}}} =
               Document.from_map(%{
                 "mcp_servers" => %{"x" => %{"transport" => "stdio"}},
                 "steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}}
               })
    end
  end

  describe "executor" do
    test "exposes mcp tools to a workflow tool step", %{} do
      elixir = System.find_executable("elixir") || flunk("elixir binary not on PATH")

      {:ok, doc} =
        Document.from_map(%{
          "mcp_servers" => %{
            "echo" => %{
              "transport" => "stdio",
              "command" => elixir,
              "args" => [@echo_script]
            }
          },
          "steps" => %{
            "ping" => %{
              "kind" => "tool",
              "id" => "echo.echo",
              "args" => %{"value" => "from-workflow"}
            }
          },
          "output" => "${steps.ping.output}"
        })

      assert {:ok, "echo: from-workflow"} = Workflows.run(doc, %{}, [])
    end
  end
end

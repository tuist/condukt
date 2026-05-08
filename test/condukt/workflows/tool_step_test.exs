defmodule Condukt.Workflows.ToolStepTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows.{Document, Executor}

  defp doc(map) do
    {:ok, doc} = Document.from_map(map)
    doc
  end

  defp inline_echo do
    Condukt.tool(
      name: "echo",
      description: "Echoes its args back.",
      parameters: %{
        type: "object",
        properties: %{value: %{type: "string"}},
        required: ["value"]
      },
      call: fn args, _ctx -> {:ok, args} end
    )
  end

  describe "tool step" do
    test "invokes a tool by id and records the output" do
      doc =
        doc(%{
          "steps" => %{
            "echo" => %{
              "kind" => "tool",
              "id" => "echo",
              "args" => %{"value" => "hello"}
            }
          },
          "output" => "${steps.echo.output}"
        })

      assert {:ok, %{output: %{"value" => "hello"}}} =
               Executor.run(doc, %{}, tools: %{"echo" => inline_echo()})
    end

    test "interpolates input expressions into args" do
      doc =
        doc(%{
          "inputs" => %{"name" => %{"type" => "string"}},
          "steps" => %{
            "echo" => %{
              "kind" => "tool",
              "id" => "echo",
              "args" => %{"value" => "hi ${inputs.name}"}
            }
          },
          "output" => "${steps.echo.output.value}"
        })

      assert {:ok, %{output: "hi world"}} =
               Executor.run(doc, %{"name" => "world"}, tools: %{"echo" => inline_echo()})
    end

    test "errors when the id is unknown" do
      doc =
        doc(%{
          "steps" => %{"x" => %{"kind" => "tool", "id" => "nope"}}
        })

      assert {:error, {:tool_failed, "x", {:unknown_tool, "nope"}}} = Executor.run(doc)
    end

    test "records a structured error when the tool returns {:error, _}" do
      failing =
        Condukt.tool(
          name: "boom",
          description: "Always errors.",
          parameters: %{type: "object", properties: %{}},
          call: fn _args, _ctx -> {:error, "kaboom"} end
        )

      doc =
        doc(%{
          "steps" => %{"boom" => %{"kind" => "tool", "id" => "boom"}},
          "output" => "${steps.boom}"
        })

      assert {:ok, %{output: %{"ok" => false, "error" => "kaboom"}}} =
               Executor.run(doc, %{}, tools: %{"boom" => failing})
    end
  end
end

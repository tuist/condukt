defmodule Condukt.Workflows.HCLWorkflowTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows

  @moduletag :tmp_dir

  describe "Workflows.run/3 with .hcl file content" do
    test "runs HCL content read from a file end to end", %{tmp_dir: dir} do
      path = Path.join(dir, "echo.hcl")

      File.write!(path, """
      workflow "echo" {
        input "msg" {
          type = "string"
        }

        cmd "say" {
          argv = ["echo", input.msg]
        }

        output = task.say.stdout
      }
      """)

      source = File.read!(path)
      assert {:ok, "hello\n"} = Workflows.run(source, %{"msg" => "hello"}, path: path)
    end
  end

  describe "Workflows.check/1 with an .hcl path" do
    test "returns :ok when the normalized document is valid", %{tmp_dir: dir} do
      path = Path.join(dir, "ok.hcl")

      File.write!(path, """
      workflow "ok" {
        cmd "a" {
          argv = ["true"]
        }
      }
      """)

      assert :ok = Workflows.check(path)
    end

    test "returns an error when the normalized document fails validation", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.hcl")

      File.write!(path, """
      workflow "bad" {
        cmd "a" {
          argv = []
        }
      }
      """)

      assert {:error, {:invalid_workflow, _}} = Workflows.check(path)
    end
  end
end

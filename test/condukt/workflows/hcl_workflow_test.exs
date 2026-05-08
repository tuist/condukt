defmodule Condukt.Workflows.HCLWorkflowTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows

  @moduletag :tmp_dir

  describe "Workflows.run/3 with an .hcl path" do
    test "compiles and runs the workflow end to end", %{tmp_dir: dir} do
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

      assert {:ok, "hello\n"} = Workflows.run(path, %{"msg" => "hello"})
    end
  end

  describe "Workflows.check/1 with an .hcl path" do
    test "returns :ok when the compiled document matches the schema", %{tmp_dir: dir} do
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

    test "returns an error when the compiled document fails the schema", %{tmp_dir: dir} do
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

  describe "Workflows.compile/1 with an .hcl path" do
    test "emits the JSON document on success", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.hcl")

      File.write!(path, """
      workflow "hello" {
        cmd "a" {
          argv = ["true"]
        }
      }
      """)

      assert {:ok, json} = Workflows.compile(path)
      decoded = JSON.decode!(json)
      assert decoded["name"] == "hello"
      assert decoded["steps"]["a"]["kind"] == "cmd"
    end

    test "rejects a non-authored workflow file", %{tmp_dir: dir} do
      path = Path.join(dir, "x.json")
      File.write!(path, "{}")
      assert {:error, {:unsupported_compile_extension, ^path, ".json"}} = Workflows.compile(path)
    end
  end
end

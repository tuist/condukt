defmodule Condukt.WorkflowsTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows

  @moduletag :tmp_dir

  describe "run/3" do
    test "runs a workflow with a cmd step and returns the resolved output", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.json")

      File.write!(path, ~s({
        "inputs": {"name": {"type": "string"}},
        "steps": {
          "greet": {"kind": "cmd", "argv": ["echo", "hello, ${inputs.name}"]}
        },
        "output": "${steps.greet.stdout}"
      }))

      assert {:ok, "hello, world\n"} = Workflows.run(path, %{"name" => "world"})
    end

    test "branches with when:", %{tmp_dir: dir} do
      path = Path.join(dir, "branch.json")

      File.write!(path, ~s({
        "inputs": {"mode": {"type": "string"}},
        "steps": {
          "approve": {
            "kind": "cmd",
            "argv": ["echo", "approved"],
            "when": "${inputs.mode == \\"approve\\"}"
          },
          "deny": {
            "kind": "cmd",
            "argv": ["echo", "rejected"],
            "when": "${inputs.mode != \\"approve\\"}"
          }
        },
        "output": {
          "approved": "${steps.approve.stdout}",
          "denied": "${steps.deny.stdout}"
        }
      }))

      assert {:ok, %{"approved" => "approved\n", "denied" => nil}} =
               Workflows.run(path, %{"mode" => "approve"})

      assert {:ok, %{"approved" => nil, "denied" => "rejected\n"}} =
               Workflows.run(path, %{"mode" => "deny"})
    end

    test "errors when the file is missing" do
      assert {:error, {:read_failed, "/nope/missing.json", :enoent}} =
               Workflows.run("/nope/missing.json", %{})
    end

    test "errors when the JSON is malformed", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "{ not json")
      assert {:error, {:decode_failed, ^path, _reason}} = Workflows.run(path, %{})
    end

    test "errors when the document fails schema validation", %{tmp_dir: dir} do
      path = Path.join(dir, "invalid.json")
      File.write!(path, ~s({"steps": {"a": {"kind": "magic"}}}))

      assert {:error, {:invalid_workflow, %JSV.ValidationError{}}} =
               Workflows.run(path, %{})
    end
  end

  describe "load/1 and run/3 with a loaded document" do
    test "loads once and evaluates as a library", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.hcl")

      File.write!(path, """
      workflow "hello" {
        input "name" {
          type = "string"
        }

        cmd "greet" {
          argv = ["echo", "hi ${input.name}"]
        }

        output = task.greet.stdout
      }
      """)

      assert {:ok, workflow} = Workflows.load(path)
      assert {:ok, "hi world\n"} = Workflows.run(workflow, %{"name" => "world"})
    end

    test "library options override workflow runtime defaults", %{tmp_dir: dir} do
      configured_cwd = Path.join(dir, "configured")
      override_cwd = Path.join(dir, "override")
      File.mkdir_p!(configured_cwd)
      File.mkdir_p!(override_cwd)

      path = Path.join(dir, "runtime.hcl")

      File.write!(path, """
      workflow "runtime" {
        runtime {
          sandbox = "local"
          cwd = "#{configured_cwd}"
        }

        cmd "pwd" {
          argv = ["pwd"]
        }

        output = task.pwd.stdout
      }
      """)

      assert {:ok, workflow} = Workflows.load(path)
      assert {:ok, output} = Workflows.run(workflow, %{}, cwd: override_cwd)
      assert String.trim(output) == override_cwd
    end
  end

  describe "run_document/3" do
    test "runs an in-memory document" do
      decoded = %{
        "steps" => %{"hi" => %{"kind" => "cmd", "argv" => ["echo", "hi"]}},
        "output" => "${steps.hi.stdout}"
      }

      assert {:ok, "hi\n"} = Workflows.run_document(decoded)
    end

    test "rejects an invalid document" do
      decoded = %{"steps" => %{"x" => %{"kind" => "magic"}}}
      assert {:error, {:invalid_workflow, _}} = Workflows.run_document(decoded)
    end
  end

  describe "check/1" do
    test "returns :ok for a valid file", %{tmp_dir: dir} do
      path = Path.join(dir, "ok.json")
      File.write!(path, ~s({"steps": {"a": {"kind": "cmd", "argv": ["true"]}}}))
      assert :ok = Workflows.check(path)
    end

    test "returns an error when the schema rejects the document", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, ~s({"steps": {"a": {"kind": "magic"}}}))
      assert {:error, {:invalid_workflow, _}} = Workflows.check(path)
    end
  end
end

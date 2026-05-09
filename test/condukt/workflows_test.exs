defmodule Condukt.WorkflowsTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows

  @moduletag :tmp_dir

  describe "run/3" do
    test "runs a workflow with a cmd step and returns the resolved output", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.hcl")

      File.write!(path, """
      workflow "hello" {
        input "name" {
          type = "string"
        }

        cmd "greet" {
          argv = ["echo", "hello, ${input.name}"]
        }

        output = task.greet.stdout
      }
      """)

      assert {:ok, "hello, world\n"} = Workflows.run(path, %{"name" => "world"})
    end

    test "branches with when:", %{tmp_dir: dir} do
      path = Path.join(dir, "branch.hcl")

      File.write!(path, """
      workflow "branch" {
        input "mode" {
          type = "string"
        }

        cmd "approve" {
          argv = ["echo", "approved"]
          when = input.mode == "approve"
        }

        cmd "deny" {
          argv = ["echo", "rejected"]
          when = input.mode != "approve"
        }

        output = {
          approved = task.approve.stdout,
          denied = task.deny.stdout
        }
      }
      """)

      assert {:ok, %{"approved" => "approved\n", "denied" => nil}} =
               Workflows.run(path, %{"mode" => "approve"})

      assert {:ok, %{"approved" => nil, "denied" => "rejected\n"}} =
               Workflows.run(path, %{"mode" => "deny"})
    end

    test "errors when the file is missing" do
      assert {:error, {:read_failed, "/nope/missing.hcl", :enoent}} =
               Workflows.run("/nope/missing.hcl", %{})
    end

    test "errors when the document fails validation", %{tmp_dir: dir} do
      path = Path.join(dir, "invalid.hcl")

      File.write!(path, """
      workflow "invalid" {
        cmd "a" {
          argv = []
        }
      }
      """)

      assert {:error, {:invalid_workflow, {:empty_list, [:workflow, "steps", "a", "argv"]}}} =
               Workflows.run(path, %{})
    end
  end

  describe "load_hcl/2, run_hcl/3, and run/3 with a loaded document" do
    test "loads an HCL string once and evaluates it as a library" do
      source = """
      workflow "hello" {
        input "name" {
          type = "string"
        }

        cmd "greet" {
          argv = ["echo", "hi ${input.name}"]
        }

        output = task.greet.stdout
      }
      """

      assert {:ok, workflow} = Workflows.load_hcl(source)
      assert {:ok, "hi world\n"} = Workflows.run(workflow, %{"name" => "world"})
    end

    test "runs an HCL string in one call" do
      source = """
      workflow "hello" {
        input "name" {
          type = "string"
        }

        cmd "greet" {
          argv = ["echo", "hi ${input.name}"]
        }

        output = task.greet.stdout
      }
      """

      assert {:ok, "hi world\n"} = Workflows.run_hcl(source, %{"name" => "world"})
    end

    test "reports compile errors for HCL strings with the optional diagnostic path" do
      source = """
      workflow "hello" {
        cmd "a" {
          argv = ["echo", task.missing.stdout]
        }
      }
      """

      assert {:error, {:compile_failed, "inline.hcl", {:missing_needs, "a", ["missing"]}}} =
               Workflows.load_hcl(source, path: "inline.hcl")
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

    test "returns an error when validation rejects the document", %{tmp_dir: dir} do
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

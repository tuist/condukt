defmodule Condukt.Workflows.StarlarkCompileTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows

  @moduletag :tmp_dir

  describe "Workflows.compile/1" do
    test "compiles a minimal .star to a JSON document", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.star")

      File.write!(path, ~S"""
      workflow(
          name = "hello",
          inputs = {"name": {"type": "string"}},
          steps = {
              "greet": {"kind": "cmd", "argv": ["echo", "hi ${inputs.name}"]},
          },
          output = "${steps.greet.stdout}",
      )
      """)

      assert {:ok, json} = Workflows.compile(path)

      decoded = JSON.decode!(json)
      assert decoded["name"] == "hello"
      assert decoded["$schema"] =~ "condukt.workflow.schema.json"
      assert decoded["steps"]["greet"]["kind"] == "cmd"
      assert decoded["output"] == "${steps.greet.stdout}"
    end

    test "supports compile-time `for` to generate steps", %{tmp_dir: dir} do
      path = Path.join(dir, "fanout.star")

      File.write!(path, ~S"""
      steps = {}
      for i in [1, 2, 3]:
          steps["step_" + str(i)] = {"kind": "cmd", "argv": ["echo", str(i)]}

      workflow(steps = steps)
      """)

      assert {:ok, json} = Workflows.compile(path)
      decoded = JSON.decode!(json)
      assert Map.has_key?(decoded["steps"], "step_1")
      assert Map.has_key?(decoded["steps"], "step_2")
      assert Map.has_key?(decoded["steps"], "step_3")
    end

    test "rejects a file that does not call workflow(...)", %{tmp_dir: dir} do
      path = Path.join(dir, "no_call.star")
      File.write!(path, "x = 1\n")
      assert {:error, {:eval_error, _}} = Workflows.compile(path)
    end

    test "rejects a file with a parse error", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.star")
      File.write!(path, "workflow(steps =\n")
      assert {:error, {:parse_error, _}} = Workflows.compile(path)
    end

    test "rejects a non-.star file", %{tmp_dir: dir} do
      path = Path.join(dir, "x.json")
      File.write!(path, "{}")
      assert {:error, {:not_a_starlark_file, ^path, ".json"}} = Workflows.compile(path)
    end
  end

  describe "Workflows.run/3 with a .star path" do
    test "compiles and executes the .star workflow end to end", %{tmp_dir: dir} do
      path = Path.join(dir, "echo.star")

      File.write!(path, ~S"""
      workflow(
          inputs = {"msg": {"type": "string"}},
          steps = {
              "say": {"kind": "cmd", "argv": ["echo", "${inputs.msg}"]},
          },
          output = "${steps.say.stdout}",
      )
      """)

      assert {:ok, "hello\n"} = Workflows.run(path, %{"msg" => "hello"})
    end
  end

  describe "Workflows.check/1 with a .star path" do
    test "validates a Starlark workflow against the schema", %{tmp_dir: dir} do
      path = Path.join(dir, "ok.star")

      File.write!(path, ~S"""
      workflow(steps = {"a": {"kind": "cmd", "argv": ["true"]}})
      """)

      assert :ok = Workflows.check(path)
    end

    test "rejects a Starlark workflow that produces an invalid document", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.star")

      File.write!(path, ~S"""
      workflow(steps = {"a": {"kind": "magic"}})
      """)

      assert {:error, {:invalid_workflow, _}} = Workflows.check(path)
    end
  end
end

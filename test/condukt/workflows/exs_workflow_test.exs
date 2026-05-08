defmodule Condukt.Workflows.ExsWorkflowTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows

  @moduletag :tmp_dir

  describe "Workflows.run/3 with a .exs path" do
    test "evaluates and runs the workflow end to end", %{tmp_dir: dir} do
      path = Path.join(dir, "echo.exs")

      File.write!(path, """
      %{
        inputs: %{msg: %{type: :string}},
        steps: %{
          say: %{kind: :cmd, argv: ["echo", "${inputs.msg}"]}
        },
        output: "${steps.say.stdout}"
      }
      """)

      assert {:ok, "hello\n"} = Workflows.run(path, %{"msg" => "hello"})
    end
  end

  describe "Workflows.check/1 with a .exs path" do
    test "returns :ok when the evaluated map matches the schema", %{tmp_dir: dir} do
      path = Path.join(dir, "ok.exs")

      File.write!(path, """
      %{steps: %{a: %{kind: :cmd, argv: ["true"]}}}
      """)

      assert :ok = Workflows.check(path)
    end

    test "returns an error when the evaluated map fails the schema", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.exs")

      File.write!(path, """
      %{steps: %{a: %{kind: :magic}}}
      """)

      assert {:error, {:invalid_workflow, _}} = Workflows.check(path)
    end
  end

  describe "Workflows.compile/1 with a .exs path" do
    test "emits the JSON document on success", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.exs")

      File.write!(path, """
      %{
        name: "hello",
        steps: %{a: %{kind: :cmd, argv: ["true"]}}
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

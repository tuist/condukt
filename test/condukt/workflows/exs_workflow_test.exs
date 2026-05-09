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
    test "returns :ok when the evaluated map is valid", %{tmp_dir: dir} do
      path = Path.join(dir, "ok.exs")

      File.write!(path, """
      %{steps: %{a: %{kind: :cmd, argv: ["true"]}}}
      """)

      assert :ok = Workflows.check(path)
    end

    test "returns an error when the evaluated map fails validation", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.exs")

      File.write!(path, """
      %{steps: %{a: %{kind: :magic}}}
      """)

      assert {:error, {:invalid_workflow, _}} = Workflows.check(path)
    end
  end
end

defmodule Mix.Tasks.Condukt.RunTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Condukt.Run

  @moduletag :tmp_dir

  test "runs a workflow file and prints the resolved output", %{tmp_dir: dir} do
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

    output =
      capture_io(fn ->
        Run.run([path, "--input", ~s({"msg": "ok"})])
      end)

    assert String.trim(output) == "ok"
  end

  test "exits with an error when the file is missing" do
    assert catch_exit(
             capture_io(:stderr, fn ->
               Run.run(["/nope/missing.hcl"])
             end)
           ) == {:shutdown, 1}
  end
end

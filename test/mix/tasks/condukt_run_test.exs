defmodule Mix.Tasks.Condukt.RunTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  test "runs a workflow file and prints the resolved output", %{tmp_dir: dir} do
    path = Path.join(dir, "echo.json")

    File.write!(path, ~s({
      "inputs": {"msg": {"type": "string"}},
      "steps": {
        "say": {"kind": "cmd", "argv": ["echo", "${inputs.msg}"]}
      },
      "output": "${steps.say.stdout}"
    }))

    output =
      capture_io(fn ->
        Mix.Tasks.Condukt.Run.run([path, "--input", ~s({"msg": "ok"})])
      end)

    assert String.trim(output) == "ok"
  end

  test "exits with an error when the file is missing" do
    assert catch_exit(
             capture_io(:stderr, fn ->
               Mix.Tasks.Condukt.Run.run(["/nope/missing.json"])
             end)
           ) == {:shutdown, 1}
  end
end

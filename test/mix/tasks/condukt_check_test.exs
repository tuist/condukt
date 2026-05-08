defmodule Mix.Tasks.Condukt.CheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  test "prints ok for a valid workflow", %{tmp_dir: dir} do
    path = Path.join(dir, "ok.json")
    File.write!(path, ~s({"steps": {"a": {"kind": "cmd", "argv": ["true"]}}}))

    output =
      capture_io(fn ->
        Mix.Tasks.Condukt.Check.run([path])
      end)

    assert String.trim(output) == "ok: #{path}"
  end

  test "exits with status 1 when the document fails validation", %{tmp_dir: dir} do
    path = Path.join(dir, "bad.json")
    File.write!(path, ~s({"steps": {"a": {"kind": "magic"}}}))

    assert catch_exit(
             capture_io(:stderr, fn ->
               capture_io(fn -> Mix.Tasks.Condukt.Check.run([path]) end)
             end)
           ) == {:shutdown, 1}
  end
end

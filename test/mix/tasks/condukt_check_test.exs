defmodule Mix.Tasks.Condukt.CheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Condukt.Check

  @moduletag :tmp_dir

  test "prints ok for a valid workflow", %{tmp_dir: dir} do
    path = Path.join(dir, "ok.hcl")

    File.write!(path, """
    workflow "ok" {
      cmd "a" {
        argv = ["true"]
      }
    }
    """)

    output =
      capture_io(fn ->
        Check.run([path])
      end)

    assert String.trim(output) == "ok: #{path}"
  end

  test "exits with status 1 when the document fails validation", %{tmp_dir: dir} do
    path = Path.join(dir, "bad.hcl")

    File.write!(path, """
    workflow "bad" {
      cmd "a" {
        argv = []
      }
    }
    """)

    assert catch_exit(
             capture_io(:stderr, fn ->
               capture_io(fn -> Check.run([path]) end)
             end)
           ) == {:shutdown, 1}
  end
end

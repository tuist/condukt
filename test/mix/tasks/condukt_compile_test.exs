defmodule Mix.Tasks.Condukt.CompileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  test "compiles an HCL workflow file and prints JSON", %{tmp_dir: dir} do
    path = Path.join(dir, "hello.hcl")

    File.write!(path, """
    workflow "hello" {
      cmd "a" {
        argv = ["true"]
      }
    }
    """)

    output =
      capture_io(fn ->
        Mix.Tasks.Condukt.Compile.run([path])
      end)

    assert %{"name" => "hello", "steps" => %{"a" => %{"kind" => "cmd"}}} = JSON.decode!(output)
  end
end

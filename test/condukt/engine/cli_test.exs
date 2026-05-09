defmodule Condukt.Engine.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Condukt.Engine.CLI

  test "prints the application version" do
    output =
      capture_io(fn ->
        assert CLI.main(["version"]) == 0
      end)

    assert String.trim(output) == to_string(Application.spec(:condukt, :vsn))
  end

  test "prints usage for help" do
    output =
      capture_io(fn ->
        assert CLI.main(["help"]) == 0
      end)

    assert output =~ "condukt run"
    assert output =~ "condukt check"
    refute output =~ "condukt compile"
  end

  test "returns an error for an unknown command" do
    output =
      capture_io(:stderr, fn ->
        assert CLI.main(["unknown"]) == 1
      end)

    assert output =~ "Unknown command: unknown"
  end

  test "does not expose a compile command" do
    output =
      capture_io(:stderr, fn ->
        assert CLI.main(["compile", "hello.hcl"]) == 1
      end)

    assert output =~ "Unknown command: compile"
  end
end

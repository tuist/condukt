defmodule Condukt.Workflows.CompilerTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows.Compiler

  @moduletag :tmp_dir

  describe "compile/1" do
    test "compiles a minimal map workflow", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.exs")

      File.write!(path, """
      %{
        name: "hello",
        inputs: %{name: %{type: :string}},
        steps: %{
          greet: %{kind: :cmd, argv: ["echo", "hi"]}
        },
        output: "${steps.greet.stdout}"
      }
      """)

      assert {:ok, doc} = Compiler.compile(path)
      assert doc["name"] == "hello"
      assert doc["inputs"] == %{"name" => %{"type" => "string"}}
      assert doc["steps"]["greet"]["kind"] == "cmd"
      assert doc["steps"]["greet"]["argv"] == ["echo", "hi"]
      assert doc["output"] == "${steps.greet.stdout}"
    end

    test "normalizes nested atom keys and atom values", %{tmp_dir: dir} do
      path = Path.join(dir, "atoms.exs")

      File.write!(path, """
      %{
        steps: %{
          go: %{kind: :http, method: :GET, url: "https://example.test/"}
        }
      }
      """)

      assert {:ok, doc} = Compiler.compile(path)
      assert doc["steps"]["go"]["method"] == "GET"
      assert doc["steps"]["go"]["url"] == "https://example.test/"
    end

    test "preserves nil, true, false unchanged", %{tmp_dir: dir} do
      path = Path.join(dir, "preserve.exs")

      File.write!(path, """
      %{
        steps: %{
          a: %{kind: :cmd, argv: ["true"]}
        },
        output: %{flag: true, missing: nil, off: false}
      }
      """)

      assert {:ok, doc} = Compiler.compile(path)
      assert doc["output"] == %{"flag" => true, "missing" => nil, "off" => false}
    end

    test "supports compile-time iteration to build steps", %{tmp_dir: dir} do
      path = Path.join(dir, "fanout.exs")

      File.write!(path, """
      stages = ["lint", "test", "build"]

      steps =
        for stage <- stages, into: %{} do
          {String.to_atom(stage), %{kind: :cmd, argv: ["./script/" <> stage]}}
        end

      %{steps: steps}
      """)

      assert {:ok, doc} = Compiler.compile(path)
      assert Map.has_key?(doc["steps"], "lint")
      assert Map.has_key?(doc["steps"], "test")
      assert Map.has_key?(doc["steps"], "build")
    end

    test "supports a top-level keyword list", %{tmp_dir: dir} do
      path = Path.join(dir, "kw.exs")

      File.write!(path, """
      [
        name: "kw-style",
        steps: %{a: %{kind: :cmd, argv: ["true"]}}
      ]
      """)

      assert {:ok, %{"name" => "kw-style"}} = Compiler.compile(path)
    end

    test "reports a read failure when the file is missing" do
      assert {:error, {:read_failed, "/nope/x.exs", :enoent}} = Compiler.compile("/nope/x.exs")
    end

    test "reports an eval failure when the file raises", %{tmp_dir: dir} do
      path = Path.join(dir, "boom.exs")
      File.write!(path, "raise \"kaboom\"")
      assert {:error, {:eval_failed, ^path, message}} = Compiler.compile(path)
      assert message =~ "kaboom"
    end

    test "rejects a result that is not a map", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.exs")
      File.write!(path, "1 + 1")
      assert {:error, {:not_a_workflow, ^path, :result_must_be_a_map}} = Compiler.compile(path)
    end
  end
end

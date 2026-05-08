defmodule Condukt.Workflows.DocumentTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows.Document

  @moduletag :tmp_dir

  describe "load/1" do
    test "loads, decodes, and validates a JSON workflow", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.json")

      File.write!(path, ~s({
        "inputs": {"name": {"type": "string"}},
        "steps": {
          "greet": {"kind": "cmd", "argv": ["echo", "hi"]}
        },
        "output": "${steps.greet.stdout}"
      }))

      assert {:ok, %Document{} = doc} = Document.load(path)
      assert doc.name == "hello"
      assert doc.path == path
      assert doc.inputs == %{"name" => %{"type" => "string"}}
      assert is_map(doc.steps)
      assert Map.has_key?(doc.steps, "greet")
      assert doc.output == "${steps.greet.stdout}"
    end

    test "uses the explicit name when provided", %{tmp_dir: dir} do
      path = Path.join(dir, "anon.json")

      File.write!(path, ~s({
        "name": "named-thing",
        "steps": {"a": {"kind": "cmd", "argv": ["true"]}}
      }))

      assert {:ok, %Document{name: "named-thing"}} = Document.load(path)
    end

    test "returns :read_failed when the file is missing", %{tmp_dir: dir} do
      path = Path.join(dir, "ghost.json")
      assert {:error, {:read_failed, ^path, :enoent}} = Document.load(path)
    end

    test "returns :decode_failed for invalid JSON", %{tmp_dir: dir} do
      path = Path.join(dir, "broken.json")
      File.write!(path, "{not json")
      assert {:error, {:decode_failed, ^path, _}} = Document.load(path)
    end

    test "returns :decode_failed for non-object JSON", %{tmp_dir: dir} do
      path = Path.join(dir, "list.json")
      File.write!(path, "[1, 2, 3]")
      assert {:error, {:decode_failed, ^path, :not_an_object}} = Document.load(path)
    end

    test "returns :unsupported_extension for unknown suffixes", %{tmp_dir: dir} do
      path = Path.join(dir, "weird.txt")
      File.write!(path, "{}")
      assert {:error, {:unsupported_extension, ^path}} = Document.load(path)
    end

    test "returns :invalid_workflow when the schema rejects the document", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, ~s({"steps": {"a": {"kind": "magic"}}}))
      assert {:error, {:invalid_workflow, %JSV.ValidationError{}}} = Document.load(path)
    end
  end

  describe "from_map/2" do
    test "validates an in-memory document and uses the optional path for naming" do
      decoded = %{"steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}}}
      assert {:ok, %Document{name: "scratch"}} = Document.from_map(decoded, path: "scratch.json")
    end

    test "falls back to a default name when no path is given" do
      decoded = %{"steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}}}
      assert {:ok, %Document{name: "workflow", path: nil}} = Document.from_map(decoded)
    end
  end

  describe "validate_inputs/2" do
    setup do
      doc = %Document{
        name: "x",
        steps: %{},
        inputs: %{
          "name" => %{"type" => "string"},
          "count" => %{"type" => "integer", "default" => 1}
        }
      }

      {:ok, doc: doc}
    end

    test "accepts inputs that satisfy the declared types and fills defaults", %{doc: doc} do
      assert {:ok, %{"name" => "world", "count" => 1}} =
               Document.validate_inputs(doc, %{"name" => "world"})
    end

    test "accepts a user-supplied override for a defaulted input", %{doc: doc} do
      assert {:ok, %{"name" => "world", "count" => 5}} =
               Document.validate_inputs(doc, %{"name" => "world", "count" => 5})
    end

    test "rejects when a required input is missing", %{doc: doc} do
      assert {:error, %JSV.ValidationError{}} = Document.validate_inputs(doc, %{})
    end

    test "rejects an input of the wrong type", %{doc: doc} do
      assert {:error, %JSV.ValidationError{}} =
               Document.validate_inputs(doc, %{"name" => 1})
    end

    test "rejects unknown input keys", %{doc: doc} do
      assert {:error, %JSV.ValidationError{}} =
               Document.validate_inputs(doc, %{"name" => "x", "bogus" => true})
    end
  end
end

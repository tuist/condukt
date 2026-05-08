defmodule Condukt.Workflows.HCLCompilerTest do
  use ExUnit.Case, async: false

  alias Condukt.Workflows.HCLCompiler

  @moduletag :tmp_dir

  describe "compile/1" do
    test "compiles a minimal HCL workflow", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.hcl")

      File.write!(path, """
      workflow "hello" {
        input "name" {
          type = "string"
          description = "Person to greet"
        }

        cmd "greet" {
          argv = ["echo", "Hello, ${input.name}"]
        }

        output = task.greet.stdout
      }
      """)

      assert {:ok, doc} = HCLCompiler.compile(path)
      assert doc["name"] == "hello"
      assert doc["inputs"] == %{"name" => %{"type" => "string", "description" => "Person to greet"}}
      assert doc["steps"]["greet"] == %{"kind" => "cmd", "argv" => ["echo", "Hello, ${inputs.name}"]}
      assert doc["output"] == "${steps.greet.stdout}"
    end

    test "supports every workflow step kind", %{tmp_dir: dir} do
      path = Path.join(dir, "all_kinds.hcl")

      File.write!(path, """
      workflow "all_kinds" {
        input "token" {
          type = "string"
          default = "dev"
        }

        http "fetch" {
          method = "get"
          url = "https://example.test/items"
          headers = {
            Authorization = "Bearer ${input.token}"
          }
          expect_status = [200, 204]
        }

        agent "review" {
          needs = ["fetch"]
          model = "openai:gpt-4.1-mini"
          input = task.fetch.body
          tools = ["Read"]
          system = "Review fetched data"
          output_schema = {
            type = "object"
          }
        }

        tool "readme" {
          id = "Read"
          args = {
            file_path = "README.md"
          }
        }

        map "echo_items" {
          needs = ["fetch"]
          over = task.fetch.body.items
          as = "item"

          cmd {
            argv = ["echo", item.id]
          }
        }

        output = {
          review = task.review.output,
          readme = task.readme.output
        }
      }
      """)

      assert {:ok, doc} = HCLCompiler.compile(path)
      assert doc["steps"]["fetch"]["method"] == "GET"
      assert doc["steps"]["fetch"]["headers"]["Authorization"] == "Bearer ${inputs.token}"
      assert doc["steps"]["fetch"]["expect_status"] == [200, 204]
      assert doc["steps"]["review"]["needs"] == ["fetch"]
      assert doc["steps"]["review"]["input"] == "${steps.fetch.body}"
      assert doc["steps"]["readme"]["args"] == %{"file_path" => "README.md"}

      assert doc["steps"]["echo_items"] == %{
               "kind" => "map",
               "needs" => ["fetch"],
               "over" => "${steps.fetch.body.items}",
               "as" => "item",
               "do" => %{"kind" => "cmd", "argv" => ["echo", "${item.id}"]}
             }

      assert doc["output"] == %{
               "review" => "${steps.review.output}",
               "readme" => "${steps.readme.output}"
             }
    end

    test "requires task references to be declared in needs", %{tmp_dir: dir} do
      path = Path.join(dir, "missing_needs.hcl")

      File.write!(path, """
      workflow "missing_needs" {
        cmd "a" {
          argv = ["echo", "hi"]
        }

        cmd "b" {
          argv = ["echo", task.a.stdout]
        }
      }
      """)

      assert {:error, {:missing_needs, "b", ["a"]}} = HCLCompiler.compile(path)
    end

    test "captures HXL diagnostics instead of printing parser warnings", %{tmp_dir: dir} do
      path = Path.join(dir, "quiet.hcl")

      File.write!(path, """
      workflow "quiet" {
        cmd "a" {
          argv = ["true"]
        }
      }
      """)

      assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
               assert {:ok, _doc} = HCLCompiler.compile(path)
             end) == ""
    end
  end
end

defmodule Condukt.Workflows.SchemaTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows.Schema

  describe "schema/0" do
    test "exposes the decoded schema map" do
      schema = Schema.schema()
      assert schema["title"] == "Condukt Workflow"
      assert schema["$id"] =~ "condukt.workflow.schema.json"
    end
  end

  describe "url/0" do
    test "returns the canonical raw GitHub url" do
      assert Schema.url() ==
               "https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json"
    end
  end

  describe "validation against the schema" do
    test "accepts a minimal cmd workflow" do
      doc = %{
        "name" => "hello",
        "inputs" => %{"name" => %{"type" => "string"}},
        "steps" => %{
          "greet" => %{
            "kind" => "cmd",
            "argv" => ["echo", "hello, ${inputs.name}"]
          }
        },
        "output" => "${steps.greet.stdout}"
      }

      assert {:ok, _} = JSV.validate(doc, Schema.root())
    end

    test "accepts agent, http, tool, and map step kinds" do
      doc = %{
        "steps" => %{
          "fetch" => %{
            "kind" => "http",
            "method" => "GET",
            "url" => "https://example.test/items"
          },
          "review" => %{
            "kind" => "agent",
            "model" => "claude-opus-4-7",
            "input" => "${steps.fetch.body}"
          },
          "search" => %{
            "kind" => "tool",
            "id" => "grep",
            "args" => %{"pattern" => "TODO"}
          },
          "fanout" => %{
            "kind" => "map",
            "over" => "${steps.fetch.body.items}",
            "as" => "item",
            "do" => %{
              "kind" => "cmd",
              "argv" => ["echo", "${item.id}"]
            }
          }
        }
      }

      assert {:ok, _} = JSV.validate(doc, Schema.root())
    end

    test "rejects a step with an unknown kind" do
      doc = %{"steps" => %{"oops" => %{"kind" => "magic"}}}
      assert {:error, %JSV.ValidationError{}} = JSV.validate(doc, Schema.root())
    end

    test "rejects a cmd step without argv" do
      doc = %{"steps" => %{"oops" => %{"kind" => "cmd"}}}
      assert {:error, %JSV.ValidationError{}} = JSV.validate(doc, Schema.root())
    end

    test "rejects a cmd step with an empty argv list" do
      doc = %{"steps" => %{"oops" => %{"kind" => "cmd", "argv" => []}}}
      assert {:error, %JSV.ValidationError{}} = JSV.validate(doc, Schema.root())
    end

    test "rejects a workflow with no steps" do
      doc = %{"steps" => %{}}
      assert {:error, %JSV.ValidationError{}} = JSV.validate(doc, Schema.root())
    end

    test "rejects unknown top-level keys" do
      doc = %{
        "steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}},
        "extras" => true
      }

      assert {:error, %JSV.ValidationError{}} = JSV.validate(doc, Schema.root())
    end

    test "rejects an invalid name" do
      doc = %{
        "name" => "1bad",
        "steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}}
      }

      assert {:error, %JSV.ValidationError{}} = JSV.validate(doc, Schema.root())
    end

    test "accepts an http step with expect_status as integer or list" do
      ok_int = %{
        "steps" => %{
          "a" => %{
            "kind" => "http",
            "method" => "GET",
            "url" => "https://example.test/",
            "expect_status" => 200
          }
        }
      }

      ok_list = put_in(ok_int, ["steps", "a", "expect_status"], [200, 204])

      assert {:ok, _} = JSV.validate(ok_int, Schema.root())
      assert {:ok, _} = JSV.validate(ok_list, Schema.root())
    end

    test "rejects unknown fields inside a step" do
      doc = %{
        "steps" => %{
          "a" => %{"kind" => "cmd", "argv" => ["true"], "bogus" => 1}
        }
      }

      assert {:error, %JSV.ValidationError{}} = JSV.validate(doc, Schema.root())
    end
  end
end

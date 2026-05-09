defmodule Condukt.Workflows.ValidatorTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows.Validator

  describe "validate/1" do
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

      assert {:ok, ^doc} = Validator.validate(doc)
    end

    test "accepts agent, http, tool, and map step kinds" do
      doc = %{
        "runtime" => %{
          "model" => "claude-opus-4-7",
          "sandbox" => "local",
          "cwd" => "."
        },
        "steps" => %{
          "fetch" => %{
            "kind" => "http",
            "method" => "GET",
            "url" => "https://example.test/items"
          },
          "review" => %{
            "kind" => "agent",
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

      assert {:ok, ^doc} = Validator.validate(doc)
    end

    test "rejects an unknown runtime sandbox" do
      doc = %{
        "runtime" => %{"sandbox" => "docker"},
        "steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}}
      }

      assert {:error, {:invalid_value, [:workflow, "runtime", "sandbox"], "docker", ["local", "virtual"]}} =
               Validator.validate(doc)
    end

    test "accepts an object runtime model spec" do
      doc = %{
        "runtime" => %{"model" => %{"provider" => "custom", "id" => "chat"}},
        "steps" => %{"a" => %{"kind" => "agent", "input" => "hello"}}
      }

      assert {:ok, ^doc} = Validator.validate(doc)
    end

    test "rejects a step with an unknown kind" do
      doc = %{"steps" => %{"oops" => %{"kind" => "magic"}}}
      assert {:error, {:invalid_value, [:workflow, "steps", "oops", "kind"], "magic", _}} = Validator.validate(doc)
    end

    test "rejects a cmd step without argv" do
      doc = %{"steps" => %{"oops" => %{"kind" => "cmd"}}}
      assert {:error, {:missing_key, [:workflow, "steps", "oops", "argv"]}} = Validator.validate(doc)
    end

    test "rejects a cmd step with an empty argv list" do
      doc = %{"steps" => %{"oops" => %{"kind" => "cmd", "argv" => []}}}
      assert {:error, {:empty_list, [:workflow, "steps", "oops", "argv"]}} = Validator.validate(doc)
    end

    test "rejects a workflow with no steps" do
      doc = %{"steps" => %{}}
      assert {:error, {:empty_steps, [:workflow, "steps"]}} = Validator.validate(doc)
    end

    test "rejects unknown top-level keys" do
      doc = %{
        "steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}},
        "extras" => true
      }

      assert {:error, {:unknown_keys, [:workflow], ["extras"]}} = Validator.validate(doc)
    end

    test "rejects an invalid name" do
      doc = %{
        "name" => "1bad",
        "steps" => %{"a" => %{"kind" => "cmd", "argv" => ["true"]}}
      }

      assert {:error, {:invalid_name, [:workflow, "name"], "1bad"}} = Validator.validate(doc)
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

      assert {:ok, ^ok_int} = Validator.validate(ok_int)
      assert {:ok, ^ok_list} = Validator.validate(ok_list)
    end

    test "rejects unknown fields inside a step" do
      doc = %{
        "steps" => %{
          "a" => %{"kind" => "cmd", "argv" => ["true"], "bogus" => 1}
        }
      }

      assert {:error, {:unknown_keys, [:workflow, "steps", "a"], ["bogus"]}} = Validator.validate(doc)
    end
  end
end

defmodule Condukt.Workflows.ExprTest do
  use ExUnit.Case, async: true

  alias Condukt.Workflows.Expr

  defp ctx(map \\ %{}) do
    %{
      inputs: Map.get(map, :inputs, %{}),
      steps: Map.get(map, :steps, %{}),
      bindings: Map.get(map, :bindings, %{})
    }
  end

  describe "interpolate/2 with no placeholders" do
    test "passes through plain strings unchanged" do
      assert {:ok, "hello"} = Expr.interpolate("hello", ctx())
    end
  end

  describe "interpolate/2 with a single whole-string placeholder" do
    test "preserves the underlying type" do
      assert {:ok, 7} = Expr.interpolate("${inputs.n}", ctx(%{inputs: %{"n" => 7}}))

      assert {:ok, %{"a" => 1}} =
               Expr.interpolate("${inputs.obj}", ctx(%{inputs: %{"obj" => %{"a" => 1}}}))

      assert {:ok, true} = Expr.interpolate("${inputs.flag}", ctx(%{inputs: %{"flag" => true}}))
      assert {:ok, [1, 2]} = Expr.interpolate("${inputs.xs}", ctx(%{inputs: %{"xs" => [1, 2]}}))
    end
  end

  describe "interpolate/2 with mixed text and placeholders" do
    test "stringifies and concatenates" do
      ctx = ctx(%{inputs: %{"name" => "world", "n" => 42}})
      assert {:ok, "hello, world (42)"} = Expr.interpolate("hello, ${inputs.name} (${inputs.n})", ctx)
    end

    test "stringifies booleans and nil" do
      ctx = ctx(%{inputs: %{"flag" => true, "missing" => nil}})
      assert {:ok, "flag=true missing="} = Expr.interpolate("flag=${inputs.flag} missing=${inputs.missing}", ctx)
    end
  end

  describe "expression productions" do
    test "member access and indexing" do
      ctx =
        ctx(%{
          steps: %{
            "fetch" => %{"body" => %{"items" => [%{"id" => "a"}, %{"id" => "b"}]}}
          }
        })

      assert {:ok, "a"} = Expr.interpolate(~s(${steps.fetch.body.items[0].id}), ctx)
      assert {:ok, "b"} = Expr.interpolate(~s(${steps.fetch.body.items[1].id}), ctx)
      assert {:ok, "b"} = Expr.interpolate(~s(${steps.fetch.body.items[-1].id}), ctx)
    end

    test "comparison operators" do
      ctx = ctx(%{inputs: %{"n" => 5}})
      assert {:ok, true} = Expr.interpolate("${inputs.n == 5}", ctx)
      assert {:ok, false} = Expr.interpolate("${inputs.n != 5}", ctx)
      assert {:ok, true} = Expr.interpolate("${inputs.n < 10}", ctx)
      assert {:ok, true} = Expr.interpolate("${inputs.n <= 5}", ctx)
      assert {:ok, true} = Expr.interpolate("${inputs.n >= 5}", ctx)
      assert {:ok, false} = Expr.interpolate("${inputs.n > 5}", ctx)
    end

    test "boolean operators with short-circuit" do
      ctx = ctx(%{inputs: %{"a" => true, "b" => false}})
      assert {:ok, false} = Expr.interpolate("${inputs.a && inputs.b}", ctx)
      assert {:ok, true} = Expr.interpolate("${inputs.a || inputs.b}", ctx)
      assert {:ok, false} = Expr.interpolate("${!inputs.a}", ctx)
    end

    test "literals and parens" do
      assert {:ok, true} = Expr.interpolate("${(1 < 2) && (3 > 2)}", ctx())
      assert {:ok, "lit"} = Expr.interpolate(~s(${"lit"}), ctx())
      assert {:ok, 3.5} = Expr.interpolate("${3.5}", ctx())
    end

    test "string keys with bracket indexing" do
      ctx = ctx(%{inputs: %{"map" => %{"a key" => 7}}})
      assert {:ok, 7} = Expr.interpolate(~s(${inputs.map["a key"]}), ctx)
    end
  end

  describe "formatters" do
    test ":json formatter encodes any value" do
      ctx = ctx(%{inputs: %{"x" => %{"k" => 1}}})
      assert {:ok, ~s({"k":1})} = Expr.interpolate("${inputs.x:json}", ctx)
    end

    test ":csv formatter joins a list" do
      ctx = ctx(%{inputs: %{"xs" => ["a", "b,c", "d\"e"]}})
      assert {:ok, ~s(a,"b,c","d""e")} = Expr.interpolate("${inputs.xs:csv}", ctx)
    end

    test ":csv on a non-list errors" do
      ctx = ctx(%{inputs: %{"x" => 1}})
      assert {:error, {:csv_requires_list, 1}} = Expr.interpolate("${inputs.x:csv}", ctx)
    end

    test "rejects unknown formatters" do
      assert {:error, {:unknown_formatter, "bogus"}} = Expr.parse("inputs.x:bogus")
    end
  end

  describe "errors" do
    test "unclosed placeholder" do
      assert {:error, :unclosed_placeholder} = Expr.interpolate("hello ${inputs.x", ctx())
    end

    test "undefined identifier" do
      assert {:error, {:undefined_identifier, "wat"}} = Expr.interpolate("${wat}", ctx())
    end

    test "undefined member" do
      assert {:error, {:undefined_member, "missing"}} =
               Expr.interpolate("${inputs.missing}", ctx())
    end

    test "out-of-range index" do
      ctx = ctx(%{inputs: %{"xs" => [1, 2]}})
      assert {:error, {:index_out_of_range, 5}} = Expr.interpolate("${inputs.xs[5]}", ctx)
    end

    test "incompatible comparison" do
      ctx = ctx(%{inputs: %{"a" => "x", "b" => 1}})

      assert {:error, {:incompatible_compare, :lt, "x", 1}} =
               Expr.interpolate("${inputs.a < inputs.b}", ctx)
    end
  end

  describe "interpolate_value/2" do
    test "walks lists and maps" do
      ctx = ctx(%{inputs: %{"name" => "world"}})

      input = %{
        "argv" => ["echo", "hi ${inputs.name}"],
        "env" => %{"GREETING" => "hello, ${inputs.name}"}
      }

      assert {:ok, %{"argv" => ["echo", "hi world"], "env" => %{"GREETING" => "hello, world"}}} =
               Expr.interpolate_value(input, ctx)
    end

    test "preserves non-string leaves" do
      assert {:ok, %{"n" => 1, "b" => true, "x" => nil}} =
               Expr.interpolate_value(%{"n" => 1, "b" => true, "x" => nil}, ctx())
    end
  end

  describe "references/1" do
    test "extracts step ids referenced in any nested string" do
      value = %{
        "argv" => ["echo", "${steps.fetch.body.items[0].id}"],
        "env" => %{"X" => "${steps.greet.stdout}"},
        "when" => "${steps.review.output.score < 7}"
      }

      assert ["fetch", "greet", "review"] = Expr.references(value)
    end

    test "ignores expressions that reference inputs only" do
      assert [] = Expr.references(%{"a" => "${inputs.x}", "b" => "literal"})
    end

    test "deduplicates" do
      assert ["a"] =
               Expr.references([
                 "${steps.a.x}",
                 "${steps.a.y}",
                 "${steps.a.z}"
               ])
    end
  end

  describe "bindings (map step iterator)" do
    test "uses the binding map for unknown identifiers" do
      ctx = ctx(%{bindings: %{"item" => %{"id" => "x"}}})
      assert {:ok, "x"} = Expr.interpolate("${item.id}", ctx)
    end
  end
end

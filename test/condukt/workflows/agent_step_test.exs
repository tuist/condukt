defmodule Condukt.Workflows.AgentStepTest do
  use ExUnit.Case, async: true

  alias Condukt.Test.LLMProvider
  alias Condukt.Workflows.{Document, Executor}

  defp doc(map) do
    {:ok, doc} = Document.from_map(map)
    doc
  end

  describe "agent step" do
    test "calls the LLM with the input and records the response" do
      {model, _id} = LLMProvider.model(LLMProvider.text_response("hello back"))

      doc =
        doc(%{
          "steps" => %{
            "say" => %{
              "kind" => "agent",
              "model" => "ignored",
              "input" => "say hi"
            }
          },
          "output" => "${steps.say.output}"
        })

      assert {:ok, %{output: "hello back"}} =
               Executor.run(doc, %{}, agent_options: [model: model])
    end

    test "uses the workflow runtime model when the step omits one" do
      {model, model_id} = LLMProvider.model(LLMProvider.text_response("runtime model"))

      doc =
        doc(%{
          "runtime" => %{"model" => model},
          "steps" => %{
            "say" => %{
              "kind" => "agent",
              "input" => "say hi"
            }
          },
          "output" => "${steps.say.output}"
        })

      assert {:ok, %{output: "runtime model"}} = Executor.run(doc)
      assert_receive {LLMProvider, :request, ^model_id, _context, _opts}
    end

    test "includes the system prompt and resolves expression interpolation in input" do
      {model, model_id} = LLMProvider.model(LLMProvider.text_response("acknowledged"))

      doc =
        doc(%{
          "inputs" => %{"task" => %{"type" => "string"}},
          "steps" => %{
            "do" => %{
              "kind" => "agent",
              "model" => "ignored",
              "system" => "be terse",
              "input" => "task: ${inputs.task}"
            }
          },
          "output" => "${steps.do.output}"
        })

      assert {:ok, %{output: "acknowledged"}} =
               Executor.run(doc, %{"task" => "review the PR"}, agent_options: [model: model])

      assert_receive {LLMProvider, :request, ^model_id, context, _opts}

      assert Enum.any?(context.messages, fn message ->
               message.role == :user and inspect(message.content) =~ "review the PR"
             end)
    end

    test "errors when the LLM call fails" do
      doc =
        doc(%{
          "steps" => %{
            "say" => %{
              "kind" => "agent",
              "model" => "nonexistent:model",
              "input" => "hello"
            }
          }
        })

      assert {:error, {:agent_failed, "say", _reason}} = Executor.run(doc)
    end
  end
end

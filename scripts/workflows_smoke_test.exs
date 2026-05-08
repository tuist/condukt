# Smoke-tests Condukt.Workflows end-to-end without making a real LLM request.
#
# Usage:
#
#   CONDUKT_BASHKIT_DISABLE=1 mix run scripts/workflows_smoke_test.exs
#
# What it does:
#
# 1. Writes a temporary `.exs` workflow.
# 2. Validates it with `Condukt.Workflows.check/1`.
# 3. Compiles it to the canonical JSON document.
# 4. Runs it with input.
# 5. Prints the resolved workflow output.

dir = Path.join(System.tmp_dir!(), "condukt-workflows-smoke-#{System.unique_integer([:positive])}")
path = Path.join(dir, "hello.exs")

File.mkdir_p!(dir)

File.write!(path, """
%{
  name: "hello",
  inputs: %{
    name: %{type: :string}
  },
  steps: %{
    greet: %{
      kind: :cmd,
      argv: ["echo", "Hello, ${inputs.name}"]
    }
  },
  output: "${steps.greet.stdout}"
}
""")

:ok = Condukt.Workflows.check(path)
{:ok, json} = Condukt.Workflows.compile(path)
{:ok, output} = Condukt.Workflows.run(path, %{"name" => "world"})

IO.puts("workflow: #{path}")
IO.puts("compiled bytes: #{byte_size(json)}")
IO.puts("\n--- workflow output ---")
IO.write(output)

File.rm_rf!(dir)

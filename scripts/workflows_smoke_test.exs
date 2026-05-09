# Smoke-tests Condukt.Workflows end-to-end without making a real LLM request.
#
# Usage:
#
#   mix run scripts/workflows_smoke_test.exs
#
# What it does:
#
# 1. Writes a temporary `.hcl` workflow.
# 2. Validates it with `Condukt.Workflows.check/1`.
# 3. Loads it as a workflow document.
# 4. Runs it with input.
# 5. Prints the resolved workflow output.

dir = Path.join(System.tmp_dir!(), "condukt-workflows-smoke-#{System.unique_integer([:positive])}")
path = Path.join(dir, "hello.hcl")

File.mkdir_p!(dir)

File.write!(path, """
workflow "hello" {
  input "name" {
    type = "string"
  }

  cmd "greet" {
    argv = ["echo", "Hello, ${input.name}"]
  }

  output = task.greet.stdout
}
""")

:ok = Condukt.Workflows.check(path)
{:ok, workflow} = Condukt.Workflows.load(path)
{:ok, output} = Condukt.Workflows.run(workflow, %{"name" => "world"})

IO.puts("workflow: #{path}")
IO.puts("loaded: #{workflow.name}")
IO.puts("\n--- workflow output ---")
IO.write(output)

File.rm_rf!(dir)

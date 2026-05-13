<p align="center">
  <img src="docs/assets/readme-header.png" alt="Condukt header" width="300" />
</p>

<p align="center">
  <a href="https://hex.pm/packages/condukt"><img src="https://img.shields.io/hexpm/v/condukt.svg" alt="Hex.pm" /></a>
  <a href="https://hexdocs.pm/condukt/"><img src="https://img.shields.io/badge/docs-hexdocs-blue.svg" alt="HexDocs" /></a>
  <a href="https://github.com/tuist/condukt/actions/workflows/condukt.yml"><img src="https://github.com/tuist/condukt/actions/workflows/condukt.yml/badge.svg" alt="CI" /></a>
  <a href="https://hex.pm/packages/condukt"><img src="https://img.shields.io/hexpm/dt/condukt.svg" alt="Hex.pm downloads" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/hexpm/l/condukt.svg" alt="License" /></a>
  <a href="https://github.com/tuist/condukt/stargazers"><img src="https://img.shields.io/github/stars/tuist/condukt?style=flat" alt="GitHub stars" /></a>
  <a href="https://github.com/tuist/condukt/commits/main"><img src="https://img.shields.io/github/last-commit/tuist/condukt.svg" alt="Last commit" /></a>
</p>

Condukt is an Elixir library and standalone agentic engine for building
reliable AI agents and workflow files.

Use Condukt as a Hex library when agents should live inside your OTP system.
Install the standalone `condukt` executable when you want to run HCL workflow
files from the command line, cron, CI, or webhooks. Both modes share the same
agent runtime, tool system, sandboxing model, project instructions, provider
support, structured output, redaction, secrets, streaming, and telemetry.

## Installation

Add Condukt to your Elixir application:

```elixir
def deps do
  [
    {:condukt, "~> 1.3"}
  ]
end
```

Or install the standalone workflow engine with mise:

```sh
mise use -g github:tuist/condukt
condukt version
```

## A Small Tour

This example shows the common shape: define an agent, grant tools, delegate to
a sub-agent, expose a typed operation, run one-shot tasks, stream a persistent
session, and execute a workflow.

```elixir
defmodule MyApp.ProjectAgent do
  use Condukt

  @impl true
  def model, do: "anthropic:claude-sonnet-4-20250514"

  @impl true
  def system_prompt do
    "You help maintain this repository. Prefer concrete findings and patches."
  end

  @impl true
  def tools do
    Condukt.Tools.coding_tools() ++
      [{Condukt.Tools.Command, command: "git"}]
  end

  @impl true
  def subagents do
    [
      reviewer: [
        system_prompt: "Review changes and return concise blockers first.",
        tools: Condukt.Tools.read_only_tools(),
        output: %{
          type: "object",
          properties: %{
            summary: %{type: "string"},
            blockers: %{type: "array", items: %{type: "string"}}
          },
          required: ["summary", "blockers"]
        }
      ]
    ]
  end

  operation :release_notes,
    input: %{
      type: "object",
      properties: %{version: %{type: "string"}},
      required: ["version"]
    },
    output: %{
      type: "object",
      properties: %{
        title: %{type: "string"},
        highlights: %{type: "array", items: %{type: "string"}}
      },
      required: ["title", "highlights"]
    },
    instructions: "Draft release notes from the git history and project files."
end

api_key = System.fetch_env!("ANTHROPIC_API_KEY")

{:ok, %{summary: summary}} =
  Condukt.run(MyApp.ProjectAgent, "Summarize README.md in one paragraph.",
    api_key: api_key,
    cwd: ".",
    input: %{path: "README.md"},
    input_schema: %{
      type: "object",
      properties: %{path: %{type: "string"}},
      required: ["path"]
    },
    output: %{
      type: "object",
      properties: %{summary: %{type: "string"}},
      required: ["summary"]
    }
  )

{:ok, notes} =
  MyApp.ProjectAgent.release_notes(%{version: "1.3.0"},
    api_key: api_key
  )

{:ok, agent} =
  MyApp.ProjectAgent.start_link(
    api_key: api_key,
    cwd: ".",
    redactor: Condukt.Redactors.Regex,
    compactor: {Condukt.Compactor.Sliding, keep: 40}
  )

agent
|> Condukt.stream("Review the last commit and delegate if useful.")
|> Stream.each(fn
  {:text, chunk} -> IO.write(chunk)
  {:tool_call, name, _id, _args} -> IO.puts("\nUsing #{name}")
  :done -> IO.puts("\nDone")
  _event -> :ok
end)
|> Stream.run()

workflow = """
workflow "readme_summary" {
  runtime {
    model = "anthropic:claude-sonnet-4-20250514"
    sandbox = "local"
    cwd = "."
  }

  input "path" {
    type = "string"
  }

  tool "read" {
    id = "Read"
    args = {
      path = input.path
    }
  }

  agent "summarize" {
    needs = ["read"]
    tools = ["Read"]
    input = "Summarize this file:\\n${task.read.output}"
  }

  output = task.summarize.output
}
"""

{:ok, workflow_summary} =
  Condukt.Workflows.run(workflow, %{"path" => "README.md"},
    agent_options: [api_key: api_key]
  )
```

## Documentation

Start here:

- [Overview](https://hexdocs.pm/condukt/overview.html)
- [Installation](https://hexdocs.pm/condukt/installation.html)
- [Getting Started](https://hexdocs.pm/condukt/getting_started.html)
- [Providers](https://hexdocs.pm/condukt/providers.html)

Build agents:

- [Agents](https://hexdocs.pm/condukt/agents.html)
- [Anonymous Workflows](https://hexdocs.pm/condukt/anonymous_workflows.html)
- [Tools](https://hexdocs.pm/condukt/tools.html)
- [Sub-agents](https://hexdocs.pm/condukt/subagents.html)
- [Operations](https://hexdocs.pm/condukt/Condukt.Operation.html)
- [Streaming and Events](https://hexdocs.pm/condukt/streaming_and_events.html)
- [Sessions and Persistence](https://hexdocs.pm/condukt/sessions_and_persistence.html)
- [Compaction](https://hexdocs.pm/condukt/compaction.html)

Run production workflows and integrations:

- [Workflows](https://hexdocs.pm/condukt/workflows.html)
- [MCP](https://hexdocs.pm/condukt/mcp.html)
- [HTTP Routes](https://hexdocs.pm/condukt/http_routes.html)
- [Sandbox](https://hexdocs.pm/condukt/sandbox.html)
- [Secrets](https://hexdocs.pm/condukt/secrets.html)
- [Redaction](https://hexdocs.pm/condukt/redaction.html)
- [Project Instructions](https://hexdocs.pm/condukt/project_instructions.html)
- [Telemetry](https://hexdocs.pm/condukt/telemetry.html)

## License

MIT License. See [LICENSE](LICENSE) for details.

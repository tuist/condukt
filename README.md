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

An Elixir library and standalone agentic engine for building reliable AI agents and workflow projects.

Condukt has two modes. Use it as a Hex library inside an Elixir application when you want agents embedded in your own OTP system. Install it as the `condukt` engine when you want a single executable that runs agentic workflow projects from the command line, cron, or webhooks.

The engine is built with Burrito and bundles Erlang plus Condukt's bytecode, so workflow projects can run without a local Elixir toolchain. Both modes share the same OTP-native agent runtime, tool system, sandboxing model, and multi-provider LLM support.

## Motivation

Condukt grew out of practical work building agentic workflows. We needed a framework that:

- Integrates naturally with OTP supervision trees
- Supports streaming for responsive user experiences
- Works with multiple LLM providers without vendor lock-in
- Provides extensible tooling for domain-specific capabilities

Rather than wrapping JavaScript agent frameworks, we built Condukt from scratch using idiomatic Elixir patterns. We are sharing it because Elixir is an excellent fit for building reliable AI agents.

## Features

- **OTP-native**: Agents run on GenServers and integrate naturally with supervision trees
- **Module One-shots**: `Condukt.run(MyApp.Agent, prompt)` hides transient session lifecycle for synchronous calls
- **Streaming**: Real-time event streaming for responsive UIs
- **Project Instructions**: Auto-discovers `AGENTS.md`, `CLAUDE.md`, and local skills from the project directory
- **Scoped Commands**: Expose trusted executables like `git`, `gh`, or `mix` without shell parsing
- **Tool System**: Extensible tools for file operations, shell commands, and more
- **Operations**: Compile-time typed entrypoints with JSON Schema input/output validation
- **Anonymous Workflows**: One-off `Condukt.run/2` calls with inline tools and optional structured output
- **Sub-agents**: Delegate isolated tasks to specialized child sessions with optional structured input/output contracts
- **Workflow Engine**: Standalone `condukt` executable for Starlark workflow projects, installable with mise
- **Multi-Provider**: 18+ LLM providers via [ReqLLM](https://github.com/agentjido/req_llm) (Anthropic, OpenAI, Google, etc.)
- **Redaction**: Pluggable secret redaction on outbound messages with a regex-based default
- **Session Secrets**: Resolve credentials from providers such as 1Password and expose them only to tool execution environments
- **Telemetry**: Built-in observability with `:telemetry` events

## Installation

### Library mode

Add `condukt` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:condukt, "~> 0.13"}
  ]
end
```

Use library mode when Condukt should live inside your own OTP supervision tree.

### Engine mode

Install the standalone executable from GitHub Releases with mise:

```sh
mise use -g github:tuist/condukt
condukt version
```

Use engine mode when you want to run a workflow project directly:

```sh
condukt workflows check --root .
condukt workflows run triage --root . --input '{"issue":"broken"}'
condukt workflows serve --root . --port 4000
```

The release assets include Linux x64, macOS x64, macOS arm64, and Windows x64 builds.

See the [Workflows](https://hexdocs.pm/condukt/workflows.html) guide for creating, running, and
sharing workflows. See the [Workflow Starlark API](https://hexdocs.pm/condukt/workflow_starlark_api.html)
reference for every Starlark builtin available to workflow files.

## Quick Start

### 1. Define an Agent

```elixir
defmodule MyApp.CodingAgent do
  use Condukt

  @impl true
  def tools do
    Condukt.Tools.coding_tools()
  end
end
```

### 2. Run the Agent

```elixir
# Run a prompt with the module's defaults
{:ok, response} =
  Condukt.run(MyApp.CodingAgent, "Create a GenServer that manages a counter",
    api_key: System.get_env("ANTHROPIC_API_KEY"),
    system_prompt: """
    You are an expert software engineer.
    Write clean, well-documented code.
    Always run tests after making changes.
    """
  )
```

`Condukt.run/3` starts a transient session, runs the agent loop synchronously,
returns the final response, and stops the session. The caller does not need to
manage a `GenServer` for one-shot work.

When you need conversation history or streaming, start a persistent agent:

```elixir
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: System.get_env("ANTHROPIC_API_KEY"),
    system_prompt: """
    You are an expert software engineer.
    Write clean, well-documented code.
    Always run tests after making changes.
    """
  )

Condukt.stream(agent, "Add documentation to the counter module")
|> Stream.each(fn
  {:text, chunk} -> IO.write(chunk)
  {:tool_call, name, _id, _args} -> IO.puts("\nUsing tool: #{name}")
  {:tool_result, _id, result} -> IO.puts("   Result: #{inspect(result)}")
  :done -> IO.puts("\nDone")
  _ -> :ok
end)
|> Stream.run()
```

### 3. Add a Persistent Agent to a Supervision Tree

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {MyApp.CodingAgent,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        system_prompt: "You are a helpful coding assistant."}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Supervise an agent when the process should outlive a single call. For simple
jobs, scripts, request handlers, and CI tasks, prefer `Condukt.run/3` with the
agent module.

## Running Agents

Condukt supports three run shapes:

```elixir
Condukt.run("Summarize README.md", tools: [Condukt.Tools.Read])
# Anonymous one-shot. The prompt and options define the whole run.

Condukt.run(MyApp.CodingAgent, "Refactor this module")
# Module-defined one-shot. The agent module supplies callbacks and defaults.

Condukt.run(agent_pid_or_name, "Continue from the previous answer")
# Persistent session. Conversation history lives in the running process.
```

Module-defined one-shot runs are the default fit when you want an agent's
`system_prompt/0`, `tools/0`, `model/0`, sandbox, secrets, and sub-agent
configuration, but do not need to hold state after the response returns.

```elixir
{:ok, response} =
  Condukt.run(MyApp.CodingAgent, "Summarize the project architecture.",
    model: "anthropic:claude-haiku-4-5",
    timeout: 120_000,
    max_turns: 8
  )
```

They also support structured output:

```elixir
{:ok, %{summary: summary}} =
  Condukt.run(MyApp.CodingAgent, "Read the supplied file and summarize it.",
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
```

Since Elixir modules and registered process names are both atoms,
`Condukt.run/3` treats atoms that look like Condukt agent modules as
module-defined one-shot runs. Use a pid or a non-module atom to target a
persistent registered session.

## Operations

Sometimes you don't want to chat with an agent. You want to call it like a
typed function: known input, validated output, no conversation history. The
`operation` macro declares one of those entrypoints at compile time.

```elixir
defmodule MyApp.ReviewAgent do
  use Condukt

  @impl true
  def tools do
    [
      Condukt.Tools.Read,
      {Condukt.Tools.Command, command: "gh", env: [GH_TOKEN: System.fetch_env!("GH_TOKEN")]}
    ]
  end

  operation :review_pr,
    input: %{
      type: "object",
      properties: %{
        repo: %{type: "string"},
        pr_number: %{type: "integer"}
      },
      required: ["repo", "pr_number"]
    },
    output: %{
      type: "object",
      properties: %{
        verdict: %{type: "string", enum: ["approve", "request_changes", "comment"]},
        summary: %{type: "string"},
        blockers: %{type: "array", items: %{type: "string"}}
      },
      required: ["verdict", "summary", "blockers"]
    },
    instructions: """
    1. Fetch the PR with `gh pr view <number> --repo <repo> --json files,title,body`.
    2. Read each changed file.
    3. Decide a verdict and list concrete blockers.
    """
end

# Each operation generates a typed function on the module.
{:ok, %{verdict: "approve", blockers: []}} =
  MyApp.ReviewAgent.review_pr(%{repo: "tuist/condukt", pr_number: 1})
```

Each call uses the same transient, module-defined one-shot path as
`Condukt.run(MyApp.Agent, prompt, output: schema)`, with the agent's tools
plus a synthetic `submit_result` tool whose schema *is* the declared output
schema. The agent loop runs until the model calls `submit_result`; the
captured arguments are validated against the output schema and returned. No
process needs to be supervised, and no conversation history is kept across
calls.

Reach for an operation when you want to:

- Drive agents from CI, webhooks, cron jobs, or `.exs` scripts
- Compose one agent's typed entrypoint into another agent's tool list
- Get input/output validation identical to what the LLM provider sees

Reach for a persistent agent process when continuity across turns matters:
when the next message depends on the last one.

Schemas are JSON Schema maps, validated with [JSV](https://hex.pm/packages/jsv).
Input validation runs before any LLM call; output validation runs after the
model submits its result. Operations also emit
`[:condukt, :operation, :start | :stop | :exception]` telemetry events
alongside the inner agent-loop events.

See `Condukt.Operation` for the full reference.

## Anonymous Workflows

For scripts, notebooks, jobs, and one-off automations that do not need a named
agent module, call `Condukt.run/2` with the prompt first. Condukt creates a
transient session, runs the prompt, and shuts it down when the response is
ready.

```elixir
{:ok, text} =
  Condukt.run("Summarize the project README in three bullets.",
    model: "anthropic:claude-sonnet-4-20250514",
    tools: [Condukt.Tools.Read]
  )
```

Anonymous workflows can also take typed input and return structured output:

```elixir
{:ok, %{summary: summary}} =
  Condukt.run("Read the supplied file and return a short summary.",
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
    },
    tools: [Condukt.Tools.Read]
  )
```

Use anonymous workflows when the whole task is contained in one call and no
module-level agent identity is useful. Use `Condukt.run(MyApp.Agent, prompt)`
when you want a named agent's callbacks without a persistent process. Use a
supervised agent when you need conversation history, long-lived state, or OTP
supervision.

## Sub-agents

Agents can delegate work to specialized child agents by declaring
`subagents/0`. Each child runs as its own `Condukt.Session` under the parent
session's sub-agent supervisor, with separate conversation history and its own
tools, model, and system prompt.

```elixir
defmodule MyApp.LeadAgent do
  use Condukt

  @impl true
  def subagents do
    [
      reviewer:
        {MyApp.ReviewerAgent,
         input: %{
           type: "object",
           properties: %{
             path: %{type: "string"},
             severity: %{type: "string", enum: ["low", "medium", "high"]}
           },
           required: ["path"]
         },
         output: %{
           type: "object",
           properties: %{
             findings: %{type: "array", items: %{type: "object"}},
             summary: %{type: "string"}
           },
           required: ["findings", "summary"]
         }},
      summarizer: [
        model: "anthropic:claude-haiku-4-5",
        system_prompt: "Summarize delegated context into concise notes."
      ]
    ]
  end
end
```

When sub-agents are registered, Condukt injects a `subagent` tool into the
parent. `:input` and `:output` schemas are optional. If an input schema is
declared, Condukt validates the tool call's `input` value before the child
starts. If an output schema is declared, Condukt adds a `submit_result` tool
to the child and returns the validated structured value to the parent.
Use `role: [opts]` to register an anonymous child agent inline instead of
creating a dedicated module.

See the [Sub-agents](https://hexdocs.pm/condukt/subagents.html) guide for role declarations,
inheritance, supervision, and structured contracts.

## LiveBook

Condukt works well in LiveBook notebooks with `Mix.install/1`:

```elixir
Mix.install([
  {:condukt, "~> 0.13"}
])

Application.put_env(:condukt, :api_key, System.fetch_env!("ANTHROPIC_API_KEY"))

defmodule NotebookAgent do
  use Condukt

  @impl true
  def tools do
    Condukt.Tools.read_only_tools()
  end
end

{:ok, agent} =
  NotebookAgent.start_link(
    system_prompt: "You are a helpful LiveBook assistant."
  )

{:ok, response} =
  Condukt.run(agent, "Summarize the current notebook context.")

response
```

For richer notebook output, you can stream events and render them with LiveBook/Kino cells as they arrive.

## Configuration

### API Keys

Set your API key via environment variable, application config, or option:

```elixir
# Environment variable (recommended) - ReqLLM auto-discovers these
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."

# Application config
config :condukt,
  api_key: "sk-ant-...",
  system_prompt: "You are a helpful coding assistant."

# Per-agent option
MyApp.CodingAgent.start_link(api_key: "sk-ant-...")
```

Values passed to `start_link/1` take precedence over `config :condukt`, which takes precedence over agent module defaults.

### Agent Options

```elixir
MyApp.CodingAgent.start_link(
  api_key: "sk-ant-...",                        # Overrides config :condukt, :api_key
  model: "anthropic:claude-sonnet-4-20250514",  # Overrides config/module default
  base_url: "http://localhost:11434/v1",        # Override provider's default URL
  system_prompt: "You are helpful.",            # Overrides config/module default
  thinking_level: :medium,                      # Overrides config/module default
  load_project_instructions: true,              # Auto-load AGENTS.md, CLAUDE.md, and local skills
  cwd: "/path/to/project",                      # Overrides config/default cwd
  session_store: Condukt.SessionStore.Memory,   # Optional session persistence
  redactor: Condukt.Redactors.Regex,            # Optional outbound secret redaction
  name: MyApp.CodingAgent                       # GenServer name
)
```

### Project Instructions

By default, Condukt inspects the project root configured by `cwd` at startup
and appends local project guidance to the effective system prompt:

- `AGENTS.md`
- `CLAUDE.md`
- `.agents/skills/*/SKILL.md`

Discovered skills are listed in the prompt with their file paths so the agent
can read the full `SKILL.md` instructions when needed.

```elixir
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    cwd: "/path/to/project",
    system_prompt: "You are a helpful coding assistant."
  )
```

Disable this behavior if you need a fully static prompt:

```elixir
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    load_project_instructions: false
  )
```

### Session Storage

Persisted sessions are opt-in. Provide a session store to save and restore
conversation history plus session settings.

Built-in session stores:

- `Condukt.SessionStore.Memory` stores snapshots in ETS for reuse within the current VM
- `Condukt.SessionStore.Disk` persists snapshots to disk across restarts

```elixir
# Restore within the current VM
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    session_store: {Condukt.SessionStore.Memory, key: {:coding_agent, "/tmp/project"}}
  )

# Persist to disk across restarts
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    cwd: "/tmp/project",
    session_store: Condukt.SessionStore.Disk
  )

# Custom path or custom implementation
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    session_store: {Condukt.SessionStore.Disk, path: "/tmp/condukt.session"}
  )
```

### Compaction

Long-running agents accumulate messages that grow past the model's context
window. Pass a compactor to keep history bounded. Condukt applies it after
each completed turn, and `Condukt.compact/1` triggers it manually.

```elixir
# Keep the last 40 messages
MyApp.CodingAgent.start_link(
  compactor: {Condukt.Compactor.Sliding, keep: 40}
)

# Elide oversized old tool result payloads, leave the most recent five intact
MyApp.CodingAgent.start_link(
  compactor: {Condukt.Compactor.ToolResultPrune, keep_recent: 5, max_size: 4_000}
)
```

Built-in strategies:

- `Condukt.Compactor.Sliding`: keeps the last N messages, drops orphaned
  tool results.
- `Condukt.Compactor.ToolResultPrune`: replaces oversized historical tool
  result payloads with a placeholder, preserving the surrounding reasoning.

Implement `Condukt.Compactor` to provide your own strategy. Each compaction
emits a `[:condukt, :compact, :stop]` telemetry event with `before`/`after`
message counts.

### Sensitive Data Redaction

Redaction rewrites user input and tool results before they leave the BEAM
process and reach the LLM provider. Assistant output and the system prompt
are left untouched. The original messages remain in session history; each
turn re-runs the redactor on the messages about to be sent.

The built-in `Condukt.Redactors.Regex` covers common high-precision patterns
(emails, JWTs, PEM private keys, Anthropic/OpenAI/GitHub/Google/AWS/Slack
tokens) and replaces matches with `[REDACTED:KIND]` placeholders the LLM can
still reason about.

```elixir
# Use the built-in defaults
{:ok, agent} = MyApp.CodingAgent.start_link(redactor: Condukt.Redactors.Regex)

# Add project-specific patterns to the defaults
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    redactor:
      {Condukt.Redactors.Regex,
       extra_patterns: [{~r/cust_[a-z0-9]+/, "CUSTOMER"}]}
  )
```

Implement `Condukt.Redactor` to plug in a custom redactor (e.g. NER-based
PII detection):

```elixir
defmodule MyApp.Redactor do
  @behaviour Condukt.Redactor

  @impl true
  def redact(text, _opts), do: MyApp.PiiScanner.scrub(text)
end

MyApp.CodingAgent.start_link(redactor: MyApp.Redactor)
```

### Supported Providers

Thanks to [ReqLLM](https://github.com/agentjido/req_llm), Condukt supports 18+ providers:

| Provider | Model Format |
|----------|-------------|
| Anthropic | `anthropic:claude-sonnet-4-20250514` |
| OpenAI | `openai:gpt-4o` |
| Google Gemini | `google:gemini-2.0-flash` |
| Ollama | `ollama:llama3.2` |
| Groq | `groq:llama-3.3-70b-versatile` |
| OpenRouter | `openrouter:anthropic/claude-3.5-sonnet` |
| xAI | `xai:grok-3` |
| And 12+ more... | See [ReqLLM docs](https://hexdocs.pm/req_llm) |

## Built-in Tools

### Default Tool Sets

```elixir
# Full coding tools: Read, Bash, Edit, Write
def tools, do: Condukt.Tools.coding_tools()

# Read-only: Read, Bash
def tools, do: Condukt.Tools.read_only_tools()
```

### Individual Tools

| Tool | Description |
|------|-------------|
| `Condukt.Tools.Read` | Read file contents, supports images |
| `Condukt.Tools.Bash` | Execute shell commands |
| `Condukt.Tools.Command` | Execute one trusted command without shell parsing |
| `Condukt.Tools.Edit` | Surgical file edits (find & replace) |
| `Condukt.Tools.Write` | Create or overwrite files |

### Scoped Command Grants

Prefer a parameterized `Condukt.Tools.Command` over `Condukt.Tools.Bash` when
you want to grant access to a specific executable or attach trusted
environment variables without exposing them in the prompt.

```elixir
defmodule MyApp.ReviewAgent do
  use Condukt

  @impl true
  def tools do
    [
      Condukt.Tools.Read,
      {Condukt.Tools.Command, command: "git"},
      {Condukt.Tools.Command, command: "gh", env: [GH_TOKEN: System.fetch_env!("GH_TOKEN")]}
    ]
  end
end
```

Each scoped command tool accepts:

- `args` - array of strings passed directly to the configured executable
- `cwd` - optional working directory
- `timeout` - optional timeout in seconds

## Custom Tools

Define custom tools by implementing the `Condukt.Tool` behaviour:

```elixir
defmodule MyApp.Tools.Weather do
  use Condukt.Tool

  @impl true
  def name, do: "get_weather"

  @impl true
  def description, do: "Gets the current weather for a location"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        location: %{type: "string", description: "City name"}
      },
      required: ["location"]
    }
  end

  @impl true
  def call(%{"location" => location}, _context) do
    case WeatherAPI.get(location) do
      {:ok, data} -> {:ok, "Temperature: #{data.temp}°F"}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## Events and Callbacks

Handle events during agent execution:

```elixir
defmodule MyApp.LoggingAgent do
  use Condukt

  @impl true
  def handle_event({:tool_call, name, _id, _args}, state) do
    Logger.info("Agent calling tool: #{name}")
    {:noreply, state}
  end

  @impl true
  def handle_event({:text, chunk}, state) do
    # Stream to WebSocket, etc.
    {:noreply, state}
  end

  @impl true
  def handle_event(_event, state), do: {:noreply, state}
end
```

## Telemetry

Condukt emits telemetry events for observability:

```elixir
:telemetry.attach_many(
  "my-handler",
  [
    [:condukt, :agent, :start],
    [:condukt, :agent, :stop],
    [:condukt, :tool_call, :start],
    [:condukt, :tool_call, :stop],
    [:condukt, :subagent, :start],
    [:condukt, :subagent, :stop],
    [:condukt, :operation, :start],
    [:condukt, :operation, :stop],
    [:condukt, :secrets, :resolve],
    [:condukt, :secrets, :access]
  ],
  fn event, measurements, metadata, _config ->
    Logger.info("#{inspect(event)}: #{inspect(measurements)}")
  end,
  nil
)
```

Secret telemetry includes environment variable names and counts for auditing,
but never includes resolved secret values.

Sub-agent telemetry identifies the parent agent, delegated role, child agent,
whether structured input and output contracts are configured, and whether the
delegation ended with `:ok` or `:error`. It never includes task text, structured
input values, or structured output values.

## Streaming API

The streaming API returns an enumerable of events:

```elixir
Condukt.stream(agent, "Hello")
|> Enum.each(fn event ->
  case event do
    {:text, chunk} -> IO.write(chunk)
    {:thinking, chunk} -> IO.write(IO.ANSI.faint() <> chunk <> IO.ANSI.reset())
    {:tool_call, name, id, args} -> IO.inspect({name, args})
    {:tool_result, id, result} -> IO.inspect(result)
    {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    :agent_start -> IO.puts("Agent started")
    :agent_end -> IO.puts("Agent finished")
    :turn_start -> nil
    :turn_end -> nil
    :done -> IO.puts("\nDone")
  end
end)
```

## License

MIT License - see [LICENSE](LICENSE) for details.

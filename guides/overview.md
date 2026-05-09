# Overview

Condukt is an Elixir library and standalone agentic engine for building
reliable AI agents and workflow files.

Condukt has two modes. Use it as a Hex library inside an Elixir application
when you want agents embedded in your own OTP system. Install it as the
`condukt` engine when you want a single executable that runs agentic workflow
files from the command line, cron, or webhooks.

The engine is built with Burrito and bundles Erlang plus Condukt's bytecode, so
workflow files can run without a local Elixir toolchain. Both modes share
the same OTP-native agent runtime, tool system, sandboxing model, and
multi-provider LLM support.

## Why Condukt

Condukt grew out of practical work building agentic workflows. We needed a
framework that:

* Integrates naturally with OTP supervision trees
* Supports streaming for responsive user experiences
* Works with multiple LLM providers without vendor lock-in
* Provides extensible tooling for domain-specific capabilities

Rather than wrapping JavaScript agent frameworks, Condukt is built from scratch
using idiomatic Elixir patterns.

## Capabilities

* OTP-native agents that integrate with supervision trees
* Real-time event streaming for responsive UIs
* Project instruction discovery from `AGENTS.md`, `CLAUDE.md`, and local skills
* Scoped command tools for trusted executables such as `git`, `gh`, or `mix`
* File, shell, editing, and custom domain tools
* Compile-time typed operations with JSON Schema input and output validation
* Anonymous one-off runs with inline tools and optional structured output
* Sub-agents for delegated child sessions with optional structured contracts
* HCL-authored workflow DAGs, runnable from Mix tasks or the standalone engine
* Multi-provider LLM support through ReqLLM
* Pluggable redaction, session secrets, compaction, persistence, and telemetry

Start with [Installation](installation.md) and [Getting Started](getting_started.md).
Use [Workflows](workflows.md) when the automation should live in project files
and run through the standalone engine.

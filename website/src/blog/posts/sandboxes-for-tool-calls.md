---
title: Where an agent's tools should run
date: 2026-05-03
description: "We just landed sandboxes in Condukt. Same agent, swap where the tool calls actually execute. Here is the thinking behind it."
author: The Tuist team
---

A pattern keeps coming up when people build agents on top of a real application. The agent picks up a tool call, the tool runs inside the same process that serves the rest of the app, and now your web server is also doing whatever the model decided. It uses the same memory, the same scheduler, the same blast radius. Most of the time that is fine. The moment your tools do anything heavier than reading a file, "most of the time" turns into "almost never," and you start finding model-generated subprocesses chewing through CPU next to your request handlers, scripts that fan out, compilers that spike memory, and host filesystem writes you would rather not have allowed in production. We have been chewing on this in [Condukt](https://github.com/tuist/condukt), and the latest release ships an abstraction that opens the door to addressing it: the sandbox.

## What landed

A sandbox is the layer underneath every tool that touches the filesystem or runs subprocesses. Read, write, edit, bash, glob, grep. The tool itself does not know what is on the other side. It calls into a small contract that the sandbox implements, and when the agent session starts, you pick which sandbox is on the other end. Two of them ship today. `Sandbox.Local` is the default and the one every Condukt agent has implicitly used until now. It reads and writes against the host filesystem and spawns real bash subprocesses through MuonTrap, which is still the right answer in many cases. `Sandbox.Virtual` is the new one. It is backed by [bashkit](https://github.com/everruns/bashkit), a virtual bash interpreter with an in-memory filesystem written in Rust. We ship it as a precompiled NIF so consumers do not need a Rust toolchain, and the interpreter implements about 160 bash builtins natively, including `grep`, `curl`, and `awk`, none of which spawn host processes. The filesystem is a separate VFS that lives in memory, and you can mount host directories into it explicitly when the agent does need to touch real files. We took the inspiration from [Flue Framework](https://flueframework.com/), which has been pushing this shape on the JavaScript side, and the model translates well to Elixir.

## How it looks

Picking a sandbox is a single option at session start.

<div class="code-block">{% highlight "elixir" %}defmodule MyApp.CodingAgent do
  use Condukt

  @impl true
  def tools, do: Condukt.Tools.coding_tools()
end

# Default: Local sandbox, host filesystem.
{:ok, agent} = MyApp.CodingAgent.start_link(api_key: "...")

# Virtual sandbox, no host access.
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: "...",
    sandbox: Condukt.Sandbox.Virtual
  )

# Virtual sandbox with the project mounted read-only at /workspace.
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: "...",
    sandbox:
      {Condukt.Sandbox.Virtual,
       mounts: [{File.cwd!(), "/workspace", :readonly}]}
  ){% endhighlight %}</div>

The same agent definition, the same tools, what changes is where the calls actually land. The same is true for typed operations, which spin up a transient session per call and let you swap the sandbox at the call site rather than at agent definition time.

<div class="code-block">{% highlight "elixir" %}defmodule MyApp.LintAgent do
  use Condukt

  @impl true
  def tools, do: [Condukt.Tools.Read]

  operation :lint_file,
    input: %{type: "object", properties: %{path: %{type: "string"}}, required: ["path"]},
    output: %{type: "object", properties: %{ok: %{type: "boolean"}}, required: ["ok"]},
    instructions: "Read the file and return whether it parses."
end

# Run the operation against an in-memory virtual sandbox.
{:ok, %{ok: true}} =
  MyApp.LintAgent.lint_file(%{path: "/workspace/lib/foo.ex"},
    sandbox: Condukt.Sandbox.Virtual
  ){% endhighlight %}</div>

A coding agent that drove on `Local` while you developed locally now runs on `Virtual` in production, with the same code paths exercised on both sides of the boundary.

## Why this matters

The reason we built it is not only isolation, although that matters. It is resource scoping. A Phoenix server hosting an agent that compiles a model-generated script ends up doing two jobs at once: one of them is "be a fast, evented HTTP server with predictable tail latency," the other is "be a build farm." Those jobs do not share an SLO, and putting them in the same OS process puts the predictable one at the mercy of the unpredictable one. A virtual sandbox shifts the heavy work off that critical path. The interpreter runs inside the BEAM, but every operation it performs is bounded by the abstraction we control: no host fork, no `make` chewing through your CPU budget, no subprocess to forget about. And because the sandbox is a contract rather than a fixed implementation, the next adapters we add can move the work somewhere else entirely. That is where we are headed next.

## What is next

The two sandboxes shipping today are the foundation. The contract is small enough that adapters for sandbox-provider services are a thin layer on top, and there are a few we already have in mind. [Daytona](https://daytona.io) and [E2B](https://e2b.dev) are the obvious first targets, running tool calls inside a remote sandboxed VM, which is the right shape when you want stronger isolation than a virtual interpreter and you are happy to pay for it. The one we are most excited about is [Kubernetes](https://kubernetes.io), where the sandbox spawns or attaches to a pod in a cluster you already operate. That lets teams reuse the cluster they already trust, with the resource limits, network policies, and observability they already wired up, instead of paying yet another vendor for the slice of compute that runs an agent's tool calls. All of these implement the same six primitives that Local and Virtual already implement: read, write, edit, exec, glob, grep. Everything above that is the agent definition you already wrote.

The new abstraction is in the latest release. If you are not using Condukt yet, the [getting started guide](https://hexdocs.pm/condukt/getting_started.html) is a good place to start. If you have an opinion about what an adapter for Daytona, E2B, or Kubernetes should look like before we ship it, we would love to hear it.

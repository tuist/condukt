---
title: Coding agents as runtimes
date: 2026-05-13
description: "Codex and Claude are already tuned coding harnesses. Condukt should meet them where they are and orchestrate them as runtimes."
author: The Tuist team
---

One thing that has become clear while building Condukt is that coding agents are not just another model endpoint. Tools like [Codex](https://github.com/openai/codex) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code/quickstart) are already products with their own opinions, defaults, and interaction models. They are not thin wrappers around a completion API. They are coding environments.

That matters because the quality of the result does not come only from the model. It comes from the whole harness around it: the prompts, the tool selection, the permission model, the way the agent reads files, the way it edits code, the way it summarizes work, and the assumptions it carries about how software should be changed.

We can try to recreate all of that ourselves. But why would we?

Developers already pay for subscriptions to these tools. Teams are already standardizing around them. The providers are constantly tuning them for coding tasks. If you are building a system that needs to run coding work, there is a strong argument for meeting those agents where they are instead of reducing them to a generic chat-completions interface.

This is the direction we want Condukt to support.

## Harnesses, not just models

Condukt started from a fairly standard mental model: define an agent, give it a model, give it tools, and let the session drive the loop. That model still makes sense for many tasks. If you want a constrained assistant that reads a few files, calls a few tools, and returns a structured result, owning the loop is useful.

But coding agents like Codex and Claude Code already own the loop.

They know how to explore a repository. They know how to make edits. They know how to run checks. They know how to summarize what changed. And most importantly, developers already trust them enough to put them in front of their codebases.

So the question becomes: should Condukt treat them as providers, or as runtimes?

We think the answer is runtimes.

A provider gives you tokens. A runtime gives you behavior. When you run a coding agent through its own harness, you are not just asking a model to produce text. You are delegating a unit of engineering work to a system that has been shaped around that kind of work.

## Why this matters for products

At Tuist, we are building Atlas, an AIOps platform for engineering teams. One of the things we find exciting about that space is that operational data often points at engineering work, but the handoff is still very manual.

A Grafana alert fires. Someone opens the dashboard. Someone checks logs. Someone correlates it with deploys, recent changes, flaky tests, user reports, or infrastructure events. Eventually, someone opens an issue or starts investigating locally.

There is a lot of structure in that process, but we still treat it as if it requires a human to initiate every step.

What if Atlas could start that investigation automatically?

Imagine an alert that says a service is returning more errors than usual. Atlas could gather the alert context, recent deploys, logs, traces, and the relevant repository. Then it could ask a coding agent to investigate:

> Look at this alert, inspect the recent changes around this service, and tell us whether there is a likely code-level cause. If there is, propose a minimal fix.

That is not a generic LLM task. It is a coding task. The agent needs to understand the repository, inspect files, maybe run tests, and produce a useful engineering artifact. Codex and Claude Code are exactly the kind of harnesses that are becoming good at this.

The same applies to bugs reported by users. A user reports that a workflow is failing. Atlas can collect the report, attach logs and traces, identify the project, and delegate the first pass to a coding agent. The output might be a diagnosis, a patch, or simply a better issue with the right context.

The important part is that Condukt does not need to pretend it can build a better coding harness than Codex or Claude Code. It needs to orchestrate them.

## What this looks like

The shape is small. A Condukt agent can declare that its loop is owned by an external runtime:

<div class="code-block">{% highlight "elixir" %}defmodule MyApp.Investigator do
  use Condukt.Agent,
    runtime: {Condukt.AgentRuntimes.Codex, sandbox: "workspace-write"}

  def system_prompt do
    """
    You investigate production alerts.
    Look for code-level causes, keep the change minimal, and explain your reasoning.
    """
  end
end{% endhighlight %}</div>

Then another part of the system can run it like any other Condukt agent:

<div class="code-block">{% highlight "elixir" %}{:ok, result} =
  Condukt.run(
    MyApp.Investigator,
    """
    Investigate this alert:

    Service: api
    Symptom: elevated 500s after the latest deploy
    Dashboard: https://grafana.example.com/d/api-errors
    Recent deploy: 8f4c2a1
    """,
    cwd: "/workspaces/acme/api"
  ){% endhighlight %}</div>

From Condukt's perspective, this is still an agent. It has a session id, a sandbox, secrets, project instructions, telemetry, and a place in a workflow. But internally, the coding work is delegated to the runtime. In this example, that means shelling out to `codex exec`. The Claude runtime follows the same idea with `claude --print`.

This keeps the boundary honest. Condukt orchestrates. Codex or Claude do the coding work. The system does not flatten everything into "call a model" when the actual behavior is richer than that.

## Reusing what developers already have

There is also a practical reason we like this direction: subscriptions.

Many developers and teams already have access to Codex or Claude Code. They have configured them, authenticated them, and built habits around them. If Condukt can plug into those tools, it can inherit that investment instead of asking teams to configure yet another provider key and another approximation of the same coding workflow.

This is very aligned with how developer tools should evolve. Meet developers where they are. If they are already getting good results from a coding harness, do not force them through a worse abstraction because it looks cleaner on our side.

The abstraction should respect the shape of the underlying tool.

For simple reasoning tasks, Condukt can own the loop. For coding tasks, it can delegate the loop. Both can exist under the same orchestration model.

## Where this leads

We do not think the future of developer automation is one agent to rule them all. It is more likely to be a network of specialized runtimes, each good at a certain kind of work, connected by systems that understand context, permissions, workflows, and organizational boundaries.

Condukt can be one of those systems.

It should not try to absorb every capability into itself. That would make it worse. It should provide the structure around the work: when to run, where to run, what context to pass, what secrets are available, what result is expected, and how the outcome flows back into the rest of the system.

The coding harnesses will keep improving. Codex and Claude Code will get better at understanding repositories, making changes, and validating them. The interesting work for Condukt is to make those harnesses useful inside real products and real organizations.

That is where this becomes more than a developer convenience. It becomes infrastructure for turning operational signals into engineering action.

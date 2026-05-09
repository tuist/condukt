---
title: A graph with room for agents
date: 2026-05-09
description: "We just shipped workflows in Condukt. A typed DAG of steps where some are deterministic commands and some are agentic loops with typed inputs and outputs. Here is the thinking behind it."
author: The Condukt team
---

If you have spent enough time around continuous integration, you know that the building block teams have settled on is the pipeline. A YAML file in the repository, a list of jobs, some `needs` between them, and a runner that walks the graph. People do not always call it a graph, but that is what it is. A typed, directed, mostly acyclic set of steps where each step has inputs, produces outputs, and the next step starts when its dependencies are done. It works because the shape is honest about what is happening: software delivery is a graph of work, and CI made that graph the unit of automation.

We have been thinking about that shape a lot at [Condukt](https://github.com/tuist/condukt). The agentic systems people are building today look surprisingly similar to CI. Read this file, run that command, call this API, summarize the result, decide whether to continue. The difference is that some of those nodes are deterministic, like "run the test suite," and some of them are not, like "ask a model to summarize the failure." CI pipelines were not designed for the second kind. So teams either pretend the agentic part is just a black-box command and lose the graph, or they bolt it on outside the pipeline and lose the rest. Neither felt right. The latest Condukt release ships our take on this: workflows.

## The shape we kept

A workflow in Condukt is a typed DAG of steps authored in HCL. The graph is the workflow. Inputs are declared, steps declare their dependencies in `needs`, and a single `output` expression is what the engine prints when the run is done. There is no manifest, no project layout, no lockfile. You point the engine at a `.hcl` file and run.

The simplest workflow looks like a CI pipeline you already know:

<div class="code-block">{% highlight "hcl" %}workflow "checks" {
  cmd "lint" {
    argv = ["mix", "format", "--check-formatted"]
  }

  cmd "test" {
    argv = ["mix", "test"]
  }

  cmd "package" {
    needs = ["lint", "test"]
    argv = ["mix", "hex.build"]
  }

  output = {
    lint = task.lint.ok,
    test = task.test.ok,
    package = task.package.ok
  }
}{% endhighlight %}</div>

Run it with `condukt run checks.hcl` and you get exactly what you would expect. Two parallel roots, a join, a final command. The graph is visible in the file: any reference to `task.<id>` has to declare `<id>` in `needs`, so you cannot accidentally write a workflow whose execution order is hidden from the reader. A visualizer can draw it directly from the normalized document, which is the same shape `condukt check` uses to validate a workflow without running it. That part of the design is intentionally boring. CI got the shape right. We did not want to invent a new one.

If you want to follow along, the engine is a single executable. Install it with [mise](https://mise.jdx.dev), which fetches the right precompiled build for your platform from GitHub Releases:

<div class="code-block">{% highlight "bash" %}mise use -g github:tuist/condukt
condukt version
condukt run checks.hcl{% endhighlight %}</div>

There is no project layout, no manifest, no lockfile. The workflow file is the thing. `condukt check checks.hcl` validates without running, which is the loop you want when you are generating workflows from an LLM and want to know quickly whether the document is well-formed.

## The shape we extended

Where workflows depart from CI is in what counts as a step. Alongside `cmd` and `http`, which are the deterministic kinds you would recognize, Condukt adds `agent`, `tool`, and `map`. The `agent` step is the interesting one. It runs an LLM-driven loop, with its own model, its own tool list, and its own typed output schema, and it participates in the same graph as the deterministic steps around it. The non-deterministic part is contained inside the step. The boundary around it is typed.

A simple mixed workflow makes the shape concrete:

<div class="code-block">{% highlight "hcl" %}workflow "release_notes" {
  runtime {
    model = "openai:gpt-4.1-mini"
  }

  cmd "version" {
    argv = ["sh", "-c", "git describe --tags --always"]
  }

  cmd "log" {
    argv = ["sh", "-c", "git log --oneline -n 50"]
  }

  agent "draft" {
    needs = ["version", "log"]
    input = "Draft release notes for ${task.version.stdout} from this log:\n${task.log.stdout}"
    output_schema = {
      type = "object"
      properties = {
        title = { type = "string" }
        highlights = {
          type = "array"
          items = { type = "string" }
        }
      }
      required = ["title", "highlights"]
    }
  }

  output = task.draft.output
}{% endhighlight %}</div>

Two deterministic steps gather facts: the current version and the log of recent commits. One agent step turns those facts into structured release notes. The agent does not return a free-form blob. It returns an object that matches `output_schema`, validated by the engine before the next step runs. That is the part we care about. The rest of the graph can read `task.draft.output.highlights` as if it were any other typed value, and downstream steps can branch on it, format it, or post it somewhere without ever asking a model to "please return JSON in this exact shape." The contract is enforced where it should be enforced, at the step boundary.

The same idea scales up when the work is per-item rather than monolithic. `map` is fan-out: take a list, run a nested step for each entry, collect the outputs in input order. A workflow that summarizes every guide in a project might look like this:

<div class="code-block">{% highlight "hcl" %}workflow "summarize_guides" {
  runtime {
    model = "openai:gpt-4.1-mini"
  }

  tool "files" {
    id = "Glob"
    args = {
      pattern = "guides/*.md"
    }
  }

  map "summaries" {
    needs = ["files"]
    over = task.files.output
    as = "file"

    agent {
      input = "Summarize this guide in two sentences: ${file}"
      output_schema = {
        type = "object"
        properties = {
          path = { type = "string" }
          summary = { type = "string" }
        }
        required = ["path", "summary"]
      }
    }
  }

  output = task.summaries
}{% endhighlight %}</div>

Globbing is deterministic. Summarizing each file is not. The graph holds both kinds in the same shape, and the result is a typed list the rest of the workflow can use. We have been writing these by hand and watching coding agents write them too, and the typed boundary has been the thing that makes both sides comfortable. The agent does the part it is good at, which is reading prose and producing structure. The graph does the part it is good at, which is dependency, parallelism, and validation.

## Why the typed boundary matters

The temptation when you start mixing deterministic and non-deterministic work is to let the model touch everything. It is faster in the short term. It is also how you end up with workflows that are impossible to reason about, because the same step might do five different things on five different runs and the next step has to be flexible enough to absorb all of them. Typed inputs and outputs invert that pressure. The model is given a narrow problem and a strict shape for the answer. The rest of the workflow does not have to care that an LLM was involved.

This is what we mean when we say the graph is the unit of automation. CI pipelines made that point a decade ago for deterministic work. Agentic systems give us a reason to make it again, this time with non-deterministic steps that have to behave like good citizens of the same graph. A `cmd` step has an exit code. An `http` step has a status. An `agent` step has a typed `output`. They compose because the shape of "what is true after this step finishes" is the same.

The expression sub-language that runs between steps is intentionally small. Member access, indexing, comparisons, boolean ops, literals, and a couple of formatters. No arbitrary function calls, no arithmetic beyond comparisons. Anything more substantial is a `cmd`, `agent`, or `tool` step. We made that constraint deliberately because once expressions can do real work, the document stops being inspectable. The point of the workflow file is to be the artifact a human can read, an editor can render, and an agent can write. Pushing logic into typed steps and keeping expressions thin is what keeps that promise.

## A more concrete example

The release notes workflow is a fine teaching example, but the one that has been most useful internally is closer to PR triage. A small workflow that fetches the diff for a pull request, runs the linter against the changed files, asks an agent to summarize the change, and decides whether the PR needs a human reviewer or can be auto-merged.

<div class="code-block">{% highlight "hcl" %}workflow "review_pr" {
  runtime {
    model = "openai:gpt-4.1-mini"
    sandbox = "local"
  }

  input "pr" {
    type = "number"
  }

  cmd "diff" {
    argv = ["gh", "pr", "diff", "${input.pr}"]
  }

  cmd "lint" {
    needs = ["diff"]
    argv = ["mix", "format", "--check-formatted"]
  }

  agent "summary" {
    needs = ["diff", "lint"]
    input = "Summarize this diff and judge whether it needs a human reviewer. Lint result: ${task.lint.ok}.\n\n${task.diff.stdout}"
    output_schema = {
      type = "object"
      properties = {
        risk = { type = "string", enum = ["low", "medium", "high"] }
        rationale = { type = "string" }
      }
      required = ["risk", "rationale"]
    }
  }

  cmd "auto_merge" {
    needs = ["summary"]
    when = task.summary.output.risk == "low"
    argv = ["gh", "pr", "merge", "${input.pr}", "--squash"]
  }

  output = {
    risk = task.summary.output.risk,
    merged = task.auto_merge.ok
  }
}{% endhighlight %}</div>

You can run that one with `condukt run review_pr.hcl --input '{"pr": 482}'`. The `auto_merge` step has a `when` gate that reads the agent's typed output, so the deterministic action only runs if the non-deterministic step says "low risk." If the gate is false, the step is skipped, the slot is set to `null`, and downstream references degrade gracefully instead of erroring. The graph keeps running. The shape is the same whether the agent is in the loop or not.

The `gh` CLI here is sourced through the host environment, but in real use it would be wired to a session secret resolved through the same mechanism we wrote about [a few days ago](/blog/agent-session-secrets/). Sandboxes plug in the same way. Workflow steps run through the configured sandbox when one is set. None of these features are bolted on. They are properties of the session the workflow runs inside.

## What we are exploring

The thing we are most excited about is what happens when the engine stops being a single process. Right now `condukt run` walks the graph on one machine. The shape of the workflow does not require that. Every step has a typed input and a typed output, every reference is explicit in `needs`, and the document is the canonical source of truth. That is enough information to schedule the graph across machines.

The idea we have been kicking around is a Condukt mesh. A network of engines, each registered with a set of capabilities, and a small scheduler that hands each step to the engine that is best placed to run it. A `cmd` step that needs a macOS host runs on a macOS engine. An `agent` step that needs a particular model runs on the engine closest to that provider. A `tool` step that needs a specific sandbox image runs on the engine that already has it loaded. The workflow author does not pick the engine. The author writes the graph. The mesh decides where each step lands.

We are not the first people to think about this. CI providers have moved in this direction for years, and orchestration systems like [Temporal](https://temporal.io) and [Dagster](https://dagster.io) have parts of the answer for the deterministic side. What we think is interesting is the agentic side. If a step is an LLM loop with a typed output, then the engine running it can be very far away from the engine running the next step, and the two only ever exchange the typed value. That is a different shape from "ship the entire pipeline to a runner" and we think it is the right one for graphs that mix deterministic and non-deterministic work.

There is a related piece we want to land sooner. Triggers. A workflow today is something you run with `condukt run`. We want `condukt serve` to host webhook and cron-driven runs, declared at the top of the same workflow document, so the same graph that runs from the CLI can also wake up on a GitHub event or a schedule. That is a smaller change than the mesh, but it is the one that turns workflows from a thing you invoke into a thing that is always there.

If you have an opinion about either of these, the [workflows guide](https://hexdocs.pm/condukt/workflows.html) is the place to start, and the issue tracker is the place to land it. The graph is the unit. We are building the rest around it.

---
title: Tool calls in a pod you already run
date: 2026-05-11
description: "We just shipped a Kubernetes sandbox for Condukt. One pod per session, the same agent definition, the same tools."
author: The Tuist team
---

A few weeks ago we shipped the [sandbox abstraction in Condukt](/blog/sandboxes-for-tool-calls/). The idea was that you should be able to choose where an agent's tool calls actually run, separately from how the agent is defined. The latest release adds the adapter we said we were most excited about: [Kubernetes](https://kubernetes.io).

## Why this question matters

It is tempting to leave tool calls in the same process that hosts the rest of the application. A Phoenix server, an agent inside it, a tool that touches the filesystem or runs a command. For the first version of anything, that is fine. It stops being fine the moment the agents are doing real work.

A coding agent that installs dependencies and runs a test suite is doing work that should not share an OS process with your HTTP handlers. A multi-tenant platform with dozens of sessions in flight cannot have one tenant's heavy compile tank tail latency for the other thirty. A long-running task that needs to outlive the BEAM has nowhere to go if its tool calls are bolted to that BEAM. An agent generating and executing scripts is, by construction, running untrusted code; you might want a boundary around it.

None of these are exotic situations. They show up as soon as agents stop being a nicer autocomplete and start being a real part of how a system gets work done. The question of where their tool calls run goes from academic to load-bearing.

## Sandboxes, and the Kubernetes one

A sandbox in Condukt is the layer underneath every tool that touches the filesystem or runs subprocesses. The tool itself does not know what is on the other side. It calls into a contract that the active sandbox implements. `Sandbox.Local` runs against the host filesystem. `Sandbox.Virtual` runs inside a Rust-implemented bash interpreter with an in-memory filesystem. `Sandbox.Kubernetes` runs each session inside a dedicated pod.

The Kubernetes adapter uses the [`:k8s`](https://hex.pm/packages/k8s) library and talks to the API server over HTTPS. No `kubectl` binary is involved at runtime. Every filesystem read, every filesystem write, every `exec` call goes through the Kubernetes exec API. The agent cannot reach the host running the Condukt BEAM at all.

Picking it is one option at session start.

<div class="code-block">{% highlight "elixir" %}# Minimal: current kubeconfig, "default" namespace.
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: "...",
    sandbox: Condukt.Sandbox.Kubernetes
  )

# Production-shaped: pinned image, namespace, resource limits, RBAC.
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: "...",
    sandbox: {
      Condukt.Sandbox.Kubernetes,
      image: "ghcr.io/myorg/agent-runtime:v1.4.2",
      namespace: "agents",
      service_account: "condukt-agent",
      resources: %{
        requests: %{cpu: "500m", memory: "1Gi"},
        limits: %{cpu: "2", memory: "4Gi"}
      }
    }
  ){% endhighlight %}</div>

Same agent module, same tools, same prompts. What changes is where the call lands.

A few smaller capabilities fall out of this shape and are worth naming. Each pod gets an `emptyDir` volume mounted at the session cwd, and with `restartPolicy: Always` the container can restart on crash and the workspace comes back with it. File writes stream through the exec stdin channel, so large payloads do not run into a command-line size ceiling. Pass `:workspace_source` and the pod clones a git repository at init, so the agent starts in a workspace that already has the code it is meant to work on. Project instructions (`AGENTS.md`, `CLAUDE.md`, anything under `.agents/skills/`) are read through the sandbox, so the agent picks them up from where its workspace lives rather than from the host.

## Reattaching after a crash

Once you put any of this behind a job queue, you bump into a question that does not show up locally. A worker picks up a job, opens a pod, the agent works for a few minutes, the BEAM crashes, the queue retries. With a fresh pod every time, the cloned workspace is gone, the edits are gone, the conversation starts from an empty message history, and a "retry" is a different operation from the one that died.

The shape we wanted is that the same stable identifier names everything that ought to survive a retry. The session already has an `:id`. Pass it explicitly, and the sandbox uses it to derive a deterministic pod name: existing pod, adopt it; no pod, create one. Pass `:session_store` alongside the id and the conversation snapshot is keyed by it too. The Oban job id is stable across retries and naturally in scope, which makes the wiring small:

<div class="code-block">{% highlight "elixir" %}defmodule MyApp.AgentWorker do
  use Oban.Worker, queue: :agents, max_attempts: 3

  @impl true
  def perform(%Oban.Job{id: job_id, args: %{"prompt" => prompt}}) do
    {:ok, agent} =
      MyApp.CodingAgent.start_link(
        id: job_id,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        sandbox: {Condukt.Sandbox.Kubernetes, namespace: "agents"},
        session_store: Condukt.SessionStore.Disk
      )

    Condukt.Session.run(agent, prompt)
  end
end{% endhighlight %}</div>

Three things keyed on the same `job_id`: the pod, the workspace it carries on disk, and the messages the session has already exchanged. A retry reattaches to all three.

The other half of decoupling pods from a single BEAM is what happens to a pod whose owner forgot it existed. Two layers, on purpose. Each pod carries a `condukt.tuist.dev/heartbeat-at` annotation that a worker linked to the owner process refreshes once a minute. When the owner dies, the worker dies, the annotation goes stale, and a reaper running elsewhere can delete stale pods on whatever cadence you like:

<div class="code-block">{% highlight "elixir" %}{:ok, deleted_pods} =
  Condukt.Sandbox.Kubernetes.reap_stale(
    namespace: "agents",
    stale_after: 15 * 60_000
  ){% endhighlight %}</div>

Underneath that, every pod is created with `activeDeadlineSeconds`, defaulting to eight hours. This is the cluster's own insurance. Even if Condukt forgets a pod entirely, Kubernetes reclaims it. I would rather have both than rely on either.

## Where we are now

There will probably be adapters for [Daytona](https://daytona.io) and [E2B](https://e2b.dev) too. They offer things that are non-trivial to replicate: fast cold starts, fine-grained per-tenant isolation, snapshots and forks of running sandboxes, per-second billing. If your product needs those, paying for them is the right call.

But a lot of teams do not. They want a place to run agent tool calls, with bounded resources and decent observability, and they already operate a cluster that gives them those things. For that case, the cluster is the answer. The namespaces, the RBAC, the [Grafana](https://grafana.com) dashboards, the audit logs are already wired up. Your agent's tool calls become one more workload on the same plane as everything else you operate.

That is the part that surprised me the most while building this. The Kubernetes adapter ended up not being the heavyweight option. For teams already running a cluster, it is the boring one. The agent calls go where everything else already goes.

The [sandbox guide](https://hexdocs.pm/condukt/sandbox.html) covers the auth resolution, the RBAC manifest, and the rest of the options. If you try it and something feels wrong, tell us.

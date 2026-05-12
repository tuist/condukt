---
title: Tool calls in a pod you already run
date: 2026-05-11
description: "We just shipped a Kubernetes sandbox for Condukt. One pod per session, the same agent definition, the same tools."
author: The Tuist team
---

When we [shipped the sandbox abstraction](/blog/sandboxes-for-tool-calls/) a few weeks back, we said the adapter we were most excited about was [Kubernetes](https://kubernetes.io). The latest release ships it.

I keep going back to a moment that pushed this up the list. We moved Tuist's production workloads onto a [Hetzner](https://www.hetzner.com) cluster recently. After years of paying a tax for someone else to hide the cluster from us, the surprising part was not the cost. It was the access. Manifests we read. State we inspect. Observability we wire ourselves. We had a coding agent reading our manifests and proposing changes within a couple of days. None of that was on the table before.

The next thought was unavoidable. If the cluster is already there, with the resource limits, the RBAC, the network policies, the dashboards, the audit trails, why would we run the agent's tool calls anywhere else?

## The shape

`Condukt.Sandbox.Kubernetes` creates one pod per session and routes every filesystem and process primitive through the Kubernetes exec API. It uses the [`:k8s`](https://hex.pm/packages/k8s) library and talks to the API server over HTTPS. There is no `kubectl` binary involved at runtime, and the agent cannot reach the host BEAM at all. Reads, writes, exec, all of it happens on the other side of the API server.

<div class="code-block">{% highlight "elixir" %}# Minimal: current kubeconfig, "default" namespace.
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: "...",
    sandbox: Condukt.Sandbox.Kubernetes
  )

# Production-shaped.
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

## Retries

The first time you put a session behind an [Oban](https://hexdocs.pm/oban) worker, you trip over a question that does not show up locally. A worker picks up a job, opens a pod, the agent does some work, something crashes, the queue retries. With a fresh pod every retry, the cloned repository is gone, the in-progress edits are gone, and a "retry" is now a different operation from the one that died.

We did not want to ship something that quietly punished you for using a queue.

The session already has an id. Pass `id:` to `start_link` and the sandbox uses it to derive a deterministic pod name. Existing pod? Adopt it. No pod? Create one. The Oban job id is stable across retries and already in scope, so it is the natural thing to pass:

<div class="code-block">{% highlight "elixir" %}defmodule MyApp.AgentWorker do
  use Oban.Worker, queue: :agents, max_attempts: 3

  @impl true
  def perform(%Oban.Job{id: job_id, args: %{"prompt" => prompt}}) do
    {:ok, agent} =
      MyApp.CodingAgent.start_link(
        id: job_id,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        sandbox: {Condukt.Sandbox.Kubernetes, namespace: "agents"}
      )

    Condukt.Session.run(agent, prompt)
  end
end{% endhighlight %}</div>

The BEAM crashes, Oban retries the job with the same `job_id`, and the sandbox reattaches to the pod that was already doing the work. If you want a pod that outlives a single job (a long-running session driven by many jobs), pass your own stable id instead. When an id is supplied, `shutdown/1` is a no-op and the pod outlives the BEAM process. When the work is actually done, the caller deletes the pod with `Condukt.Sandbox.Kubernetes.terminate/2`. Without an id, the session generates a UUID and the pod follows the usual lifecycle.

## Forgotten pods

The price of decoupling pods from a single BEAM process is that you have to answer the question nobody likes thinking about: what about a pod whose owner forgot it existed? Crashes happen. Deploys happen. Nodes go away.

Two layers, on purpose.

The first is a heartbeat annotation on the pod itself. When the sandbox starts, it spawns a small worker linked to the owner process that patches the pod's `condukt.tuist.dev/heartbeat-at` annotation every minute. There is nothing magical about it. The worker dies when its owner dies, and any reaper running elsewhere in your system can look at the annotation, see that the timestamp has stopped advancing, and delete the pod. The cadence is whatever you decide, and the reaper is whatever process you already use for that kind of cleanup. We did not want to invent a new lifecycle manager on top of Kubernetes for this. The existing primitives are enough:

<div class="code-block">{% highlight "elixir" %}{:ok, deleted_pods} =
  Condukt.Sandbox.Kubernetes.reap_stale(
    namespace: "agents",
    stale_after: 15 * 60_000
  ){% endhighlight %}</div>

Underneath that, every pod is created with `activeDeadlineSeconds`, defaulting to eight hours. This is the cluster's own insurance policy. Even if Condukt forgets a pod entirely, Kubernetes reclaims it. I would rather have both than rely on either.

## Where the state lives

Each pod gets an `emptyDir` volume mounted at the session cwd. With `restartPolicy: Always`, the container can restart on crash and the volume comes back with it. The cloned repository, any in-progress edits, anything the agent wrote, all of it survives across container restarts in the same pod. It does not survive pod deletion or node loss. If you need that, bake a PVC into your image and point the sandbox at it.

There is one small thing that turned out to matter more than I expected. Pass `:workspace_source` and the pod clones a git repo at init:

<div class="code-block">{% highlight "elixir" %}sandbox = {
  Condukt.Sandbox.Kubernetes,
  image: "ghcr.io/myorg/agent-runtime-with-git:v1",
  namespace: "agents",
  workspace_source: [
    git: "https://github.com/myorg/repo.git",
    ref: "main"
  ]
}{% endhighlight %}</div>

For stable `:id` sessions, the existing checkout is reused on reattach and the ref is checked out again. The clone runs inside the pod, so the image needs `git`. The default image is intentionally minimal and does not include it.

## One id, three things keyed on it

The same id that names a pod can do more than name a pod. Pair `:id` with `:session_store` and the conversation snapshot is keyed by it too. The disk store writes to `<cwd>/.condukt/sessions/<id>.store`, the memory store keys by the same tuple.

<div class="code-block">{% highlight "elixir" %}def perform(%Oban.Job{id: job_id, args: %{"prompt" => prompt}}) do
  {:ok, agent} =
    MyApp.CodingAgent.start_link(
      id: job_id,
      api_key: System.get_env("ANTHROPIC_API_KEY"),
      sandbox: {Condukt.Sandbox.Kubernetes, namespace: "agents"},
      session_store: Condukt.SessionStore.Disk
    )

  Condukt.Session.run(agent, prompt)
end{% endhighlight %}</div>

Three things keyed on the same `job_id`: the pod, the workspace, and the messages. A retry reattaches to all of them.

## Project instructions follow the workspace

`AGENTS.md`, `CLAUDE.md`, and any `.agents/skills/*/SKILL.md` the agent should know about are read from wherever the sandbox lives. If the workspace is on the host, that is the host. If the workspace is inside a pod cloned at init, that is the pod. The sandbox knows its own working directory and the session reads through it, so the agent ends up with the same system prompt regardless of which backend it is running against. There is no special case for Kubernetes anywhere in the discovery code.

## Why this and not a vendor

We will probably ship adapters for [Daytona](https://daytona.io) and [E2B](https://e2b.dev) too. They are a good fit for teams who would rather outsource the sandbox layer, and the contract is small enough that those adapters will be thin.

The honest question is whether you need what they offer. Some of it is genuinely hard to replicate: fast cold-starts, fine-grained per-tenant isolation, snapshots and forks of running sandboxes, per-second billing. If your product needs those, paying for them is the right call. But a lot of teams do not. They want a place to run agent tool calls, with bounded resources and decent observability, and they already operate a cluster that gives them those things. For that case, the cluster is the answer. The namespaces, the RBAC, the [Grafana](https://grafana.com) boards, the audit logs are already wired up. Your agent's tool calls become one more workload on the same plane as everything else you run.

That was the part that surprised me the most while building this. The Kubernetes adapter ended up not being the heavyweight option. For teams that already operate a cluster, it is the boring one. The agent calls go where everything else already goes.

The [sandbox guide](https://hexdocs.pm/condukt/sandbox.html) covers the auth resolution, the RBAC manifest, and the rest of the options. If you try it and something feels wrong, tell us.

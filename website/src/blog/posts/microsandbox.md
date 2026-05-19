---
title: Microsandbox support in Condukt
date: 2026-05-19
description: "Condukt can now run agent tool calls inside a local microVM through Microsandbox, with the same tools and the same agent definition."
author: The Tuist team
---

We have been building out the sandbox layer in [Condukt](https://github.com/tuist/condukt) so agent tool calls are not tied to one execution environment. `Sandbox.Local` runs against the host. `Sandbox.Virtual` runs inside an in-memory bash interpreter. `Sandbox.Kubernetes` runs each session in a pod. The latest addition is [`Sandbox.Microsandbox`](https://github.com/superradcompany/microsandbox), which runs those same tool calls inside a local microVM.

That gives us a useful middle ground. Sometimes the host is too open, and a pod in a cluster is more machinery than you want for local work. Microsandbox is a better fit for teams who want a real VM boundary on a developer machine, while still keeping the setup local and programmable.

## What landed

`Sandbox.Microsandbox` wraps the `microsandbox` Rust crate through a Rustler NIF. By default it boots an OCI image, bind-mounts the current workspace at `/workspace`, and routes `read`, `write`, `edit`, `bash`, `glob`, and `grep` through the guest.

<div class="code-block">{% highlight "elixir" %}{:ok, agent} =
  MyApp.CodingAgent.start_link(
    api_key: "...",
    sandbox: {Condukt.Sandbox.Microsandbox, image: "ubuntu:24.04"}
  ){% endhighlight %}</div>

Same agent definition, same tools, different execution boundary.

## Why this one matters

What makes Microsandbox interesting is that it is still local. There is no separate cluster to operate and no remote sandbox service in the middle. You get a guest filesystem, guest process execution, and a tighter boundary around the commands the agent runs, but you stay on the same laptop and keep the same project tree mounted into the session.

It also fits the Condukt model cleanly. The tools do not know or care whether they are talking to the host, a virtual filesystem, a microVM, or a Kubernetes pod. They call the sandbox contract, and the session decides where that contract lands.

## Current limits

The first version is intentionally narrow. Runtime `mount/3` is not supported yet, because Microsandbox volumes are configured at session creation time. `glob/3` and `grep/3` operate on host-backed bind mounts rather than on arbitrary guest-only paths. Network policy remains Kubernetes-only for now.

Even with those limits, this is a meaningful new option for local execution. If you want a stronger boundary than the host without jumping straight to a cluster, Microsandbox now fits in the same Condukt sandbox slot as everything else.

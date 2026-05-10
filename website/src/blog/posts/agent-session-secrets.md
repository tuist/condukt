---
title: Secrets belong in the session
date: 2026-05-03
description: "Agents need to act against real systems. We added session secrets to Condukt so credentials become part of the execution boundary, not part of the conversation."
author: The Tuist team
---

I keep coming back to a very mundane moment in agentic workflows: the agent is finally about to do something useful, and then it needs a credential. It wants to review a pull request with `gh`, run a smoke test against a staging API, publish a package, deploy a preview, or talk to a private service that the rest of the development environment already knows how to reach. None of these are exotic tasks. They are the normal work around software, and they are exactly the kind of work agents need to take on if they are going to be more than a nicer autocomplete. The uncomfortable part is what happens next. A command fails because `GH_TOKEN` is missing, the agent asks what to do, and the fastest answer is to paste the token into the conversation. It works. That is why it is tempting, and also why it is the wrong shape.

The problem is not that the model is malicious. The problem is that the value crossed a boundary it did not need to cross. Once a secret becomes text in the conversation, the whole system around the conversation has to be trusted with it: prompts, transcripts, compaction, snapshots, tool results, logs, streaming events, persistence, and any debugging surface we add later because production systems need debugging surfaces. `.env` files have a similar smell in agent workflows. They are convenient, and many tools assume them, but agents are very good at reading files. Even when ignored files are respected, the boundary is often a policy promise rather than an architectural one. I do not want Condukt to rely on the hope that the agent politely avoids the wrong file.

There is a pattern across the tools people already use, even if each one names it differently. [Aider](https://aider.chat/docs/config/api-keys.html) accepts keys through flags, environment variables, `.env` files, and YAML configuration. [Claude Code](https://code.claude.com/docs/en/env-vars) leans on environment variables and settings that shape the environment used by spawned tools. [GitHub Copilot's coding agent](https://docs.github.com/en/enterprise-cloud@latest/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/customize-the-agent-environment) takes the cloud version of the same idea: prepare an ephemeral environment, attach variables and secrets to it, and let the agent operate inside that prepared space. [1Password's `op run`](https://developer.1password.com/docs/cli/reference/commands/run/) is probably the cleanest local expression of the model. You keep a stable reference such as `op://Engineering/GitHub/token` in configuration, then resolve the value only for the subprocess that needs it. MCP authorization points at the remote version of that future, where a tool gets delegated access to a SaaS API instead of receiving a raw token. I do not think one mechanism replaces all the others. Local developer tools will keep speaking environment variables for a long time, and remote tools should move toward delegated authorization. What matters is that credentials are attached to execution, not to the task description.

## The session is the unit of access

That is the shape we landed on for Condukt: secrets belong to the session. A session is already the unit that carries the model, tools, sandbox, history, project context, events, and sometimes persistence. It is where the work starts, where tool calls happen, and where we can draw a boundary that is smaller than "whatever happens to be in this shell." A session reviewing a pull request might need `GH_TOKEN`. A session running a database migration might need `DATABASE_URL`. A session editing documentation probably needs nothing. Loading every credential into a global process and letting tools discover what they need was tolerable when a human was driving the shell. It becomes much harder to reason about when an agent can run commands, read broad parts of the filesystem, and turn command output into model context.

The API is intentionally small. An agent can return `secrets/0`, or a caller can pass `:secrets` when starting the session. Each entry maps an environment variable name to a provider-backed source. Today that can be 1Password, the host environment, or a static value for tests. The abstraction is not 1Password-specific because Condukt should not become a secret manager. Teams already have one of those. Some will use 1Password, some will use Vault, Doppler, AWS Secrets Manager, Google Secret Manager, SOPS, or something internal. The session only needs the normalized result: names and values resolved by trusted host code before the agent loop starts.

<div class="code-block">{% highlight "elixir" %}secrets: [
  GH_TOKEN: {:one_password, "op://Engineering/GitHub/token"}
]{% endhighlight %}</div>

When resolution fails, the session does not start. When it succeeds, command tools receive `GH_TOKEN` in their execution environment, while the model only needs to know that the GitHub CLI is configured. The value is not added to the system prompt, not added to user messages, and not persisted in session snapshots. The sandbox receives the environment too, which is important because sandboxing and secrets are two sides of the same capability boundary. The sandbox controls where code can run and what files it can touch. Secrets control which external systems that code can authenticate with.

<div class="code-block">{% highlight "elixir" %}defmodule MyApp.ReviewAgent do
  use Condukt

  @impl true
  def tools do
    [
      Condukt.Tools.Read,
      {Condukt.Tools.Command, command: "gh", name: "github"}
    ]
  end

  @impl true
  def secrets do
    [
      GH_TOKEN: {:one_password, "op://Engineering/GitHub/token"}
    ]
  end
end{% endhighlight %}</div>

## Redaction is not the safety model

I do not like treating redaction as the security model. If a tool subprocess receives `GH_TOKEN`, it can use `GH_TOKEN`. If the agent has access to a generic shell that receives the token, the agent can run commands that use it. That is the capability we granted, so the real safety work is in scoping the token, reducing which tools receive it, preferring short-lived credentials, and avoiding broad shells when a narrower tool would do. Redaction answers a different question: does the value need to become part of the conversation or persisted history? Usually it does not. That is why resolved session secrets are reconciled with Condukt's redaction pipeline. If a command accidentally prints the token, the stored and streamed tool result contains `[REDACTED:GH_TOKEN]`, not the value. The model can still understand what happened, but it does not learn the secret.

There are limits worth being explicit about. Very short values are not redacted because they create false positives everywhere. If a tool transforms a secret before printing it, exact-match redaction will not catch that transformed form. If you give a powerful long-lived token to a broad command tool, Condukt cannot pretend the agent does not have that power. This is the same lesson that keeps appearing around agents: once a capability exists, design the boundary around it instead of hoping downstream filters make it harmless. Redaction is still important, but it is a backstop for accidental leakage, not permissioning.

The other thing we added is telemetry, because access without a trail is hard to operate. When a session resolves secrets, Condukt emits a value-free event with the names that were resolved. When a tool receives secrets, it emits another value-free event with the tool name, tool call id when available, and the names exposed to that invocation. Not the values. The access. That gives teams something concrete to audit and measure without creating a new place where plaintext can leak. I think this becomes more important as sessions stop being little local experiments and start becoming infrastructure that runs continuously. At that point you want to know which agents are receiving which credentials, how often, and through which tools.

Concretely, the two events look like this for the `github` tool above:

<div class="code-block">{% highlight "elixir" %}{[:condukt, :secrets, :resolve], %{count: 1},
 %{agent: MyApp.ReviewAgent, names: ["GH_TOKEN"]}}

{[:condukt, :secrets, :access], %{count: 1},
 %{
   agent: MyApp.ReviewAgent,
   tool: "github",
   tool_call_id: "call_01HZX...",
   names: ["GH_TOKEN"]
 }}{% endhighlight %}</div>

That shape is intentionally boring. It is enough to build counters, traces, or audit logs around secret access, but it does not create a second secret store in your observability backend.

What I like about this feature is that it makes a capability explicit. We talk a lot about context in agent systems: give the agent more files, better instructions, better memory, better tools. Capabilities deserve the same care. A tool is a capability. A sandbox is a capability boundary. A secret is a capability. If secrets are random strings floating around prompts, files, and environments, we lose the ability to reason about what the agent can actually do. Putting them in the session is a small abstraction, but it gives us a place to declare intent, resolve access, redact accidental output, observe usage, and keep plaintext out of the model's world. That is the direction I want Condukt to move in: not hiding capabilities from agents, but making them explicit enough that we can build systems around them with less anxiety.

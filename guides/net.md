# Sandbox Net

`Condukt.Sandbox.Net` is the per-session outbound egress audit and
policy layer for the Kubernetes sandbox. Every HTTPS request the
workspace makes is intercepted, evaluated against a policy, and either
forwarded to the real destination or refused. Method, path, headers,
and body show up as telemetry on the BEAM side.

The runtime is shaped like a `Plug` pipeline. You declare an ordered
list of rules, and a per-request walk through the pipeline produces a
decision. The pipeline can mix static host matches with a runtime
decider that defers to code or to another agent.

## Quick start

```elixir
defmodule MyApp.CodingAgent do
  use Condukt

  @impl true
  def sandbox do
    {
      Condukt.Sandbox.Kubernetes,
      namespace: "agents",
      image: "ghcr.io/myorg/agent:1.4",
      net: [
        policy: %Condukt.Sandbox.Net.Policy{
          rules: [
            {Condukt.Sandbox.Net.Rule.DenyHosts, hosts: ["*.internal.example.com"]},
            {Condukt.Sandbox.Net.Rule.AllowHosts, hosts: ["api.github.com", "*.openai.com"]},
            {Condukt.Sandbox.Net.Rule.Decide,
             module: Condukt.Sandbox.Net.AgentDecider,
             opts: [agent: MyApp.NetGuard]}
          ],
          default: :deny
        }
      ]
    }
  end
end
```

That is the whole API surface most callers need to know about.

## Policy

```elixir
%Condukt.Sandbox.Net.Policy{
  rules: [...],
  default: :deny,
  decide_timeout: 5_000,
  decision_cache: true,
  context_messages: 5,
  context_metadata: %{}
}
```

`:rules` is the ordered pipeline. The runtime walks it from top to
bottom, asking each rule for an opinion on the current request. Each
rule returns one of:

  * `:allow` — let the request through, stop walking.
  * `{:deny, reason}` — refuse the request, stop walking.
  * `:continue` — pass to the next rule.

If every rule returns `:continue`, the policy's `:default` action
fires. The default is `:deny`, which fails closed.

Three rule modules ship out of the box.

### `Rule.AllowHosts` and `Rule.DenyHosts`

```elixir
{Condukt.Sandbox.Net.Rule.AllowHosts, hosts: ["api.github.com", "*.openai.com"]}
{Condukt.Sandbox.Net.Rule.DenyHosts, hosts: ["*.internal.example.com"]}
```

Both match the request's host against a list of glob patterns. `*`
matches a single DNS label, `**` matches one or more. `AllowHosts`
returns `:allow` on a hit and `:continue` otherwise; `DenyHosts` is
the symmetric deny.

Because order matters, you can pin per-policy preferences. A
`DenyHosts` for `evil.example.com` followed by an `AllowHosts` for
`*.example.com` denies the one host you care about and allows the
rest. Swap the order and the deny wins for everyone.

### `Rule.Decide`

```elixir
{Condukt.Sandbox.Net.Rule.Decide, fun: fn _ctx, _req -> :allow end}
{Condukt.Sandbox.Net.Rule.Decide, mf: {MyApp.Guard, :decide}}
{Condukt.Sandbox.Net.Rule.Decide,
 module: Condukt.Sandbox.Net.AgentDecider,
 opts: [agent: MyApp.NetGuard]}
```

The decide rule defers to a callable. Three shapes are accepted: a
2-arity function under `:fun`, an `{module, function}` MFA tuple under
`:mf`, or a behaviour-backed `:module` with `:opts`. The behaviour is
`Condukt.Sandbox.Net.Decider`.

The decide rule never returns `:continue`. Whatever the callable
returns becomes the request's decision. If you want a tiered policy
where the agent only sees uncertain hosts, put your narrower rules
ahead of the decide rule.

### Custom rules

Any module implementing the `Condukt.Sandbox.Net.Rule` behaviour can
appear in the pipeline. The callback receives the session context, the
request, and the opts the rule was configured with. Returns must be
`:allow`, `{:deny, reason}`, or `:continue`.

## The decider context

When `Rule.Decide` invokes a callable, it hands the callable a
`Condukt.Sandbox.Net.Context` struct alongside the request. The context
carries:

  * `:session_id` — the gated session's id.
  * `:recent_messages` — the last `policy.context_messages` entries
    from the session's message history, oldest first.
  * `:request` — the request the workspace is about to make.
  * `:metadata` — caller-supplied per-session static metadata
    (`policy.context_metadata`). Useful for user identity, tenant,
    purpose.

## Agent deciders

`Condukt.Sandbox.Net.AgentDecider` is a thin wrapper that runs a
`Condukt`-defined agent as a decider. The agent receives the context
and the request as JSON and is expected to return structured output of
the form `%{"decision" => "allow" | "deny", "reason" => "..."}`.

```elixir
defmodule MyApp.NetGuard do
  use Condukt, runtime: Condukt.AgentRuntimes.Claude

  @impl true
  def system_prompt do
    """
    You gate outbound network requests for an AI coding agent.

    You will receive a JSON object with `request.host`, `request.port`,
    `request.scheme`, `recent_messages`, and `metadata`. Decide whether
    to allow this connection.

    Reply with ONLY a JSON object, no prose, no code fences:
      {"decision": "allow" | "deny", "reason": "..."}
    """
  end
end
```

The decider agent runs as a sub-agent of the gated session, so its
own outbound traffic does not route through the same policy it is
helping to enforce.

## Timeouts and caching

`:decide_timeout` (default 5000ms) bounds how long the runtime waits
for a decider response before treating it as a failure. On timeout the
request is denied with reason `:decider_timeout`.

`:decision_cache` (default `true`) memoises decider answers per-session
per-host. Once the model has said `:deny` to `evil.com`, the next
attempt does not pay another model call.

## Telemetry

The sidecar reports every request lifecycle step over telemetry on the
BEAM side. Attach handlers with `:telemetry.attach/4`:

```
[:condukt, :sandbox, :net, :request_opened]
[:condukt, :sandbox, :net, :request_allowed]
[:condukt, :sandbox, :net, :request_denied]
[:condukt, :sandbox, :net, :request_closed]
```

Measurements: `%{bytes_in: integer, bytes_out: integer}`.
Metadata: `%{request: Condukt.Sandbox.Net.Request.t(), reason: atom() | binary() | nil}`.

`:request` carries the full `Condukt.Sandbox.Net.Request`, including
method, path, request headers, response status, and timestamps where
the sidecar could derive them. Pipe these events into whatever
observability stack you already run.

## Workspace images

The sidecar terminates TLS with a per-session ephemeral CA, so the
workspace's HTTPS client has to trust that CA. The Kubernetes sandbox
arranges that without asking the workspace image to do anything.

Two complementary mechanisms ship CA trust into the pod:

  1. **Env vars** for language stacks that consult them at runtime.
     The pod spec sets `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`,
     `SSL_CERT_FILE`, `PIP_CERT`, `CURL_CA_BUNDLE`, and
     `GIT_SSL_CAINFO`, all pointed at `/etc/condukt/ca.pem`. Node,
     Python (`requests`, `httpx`), pip, curl, git, Ruby `Net::HTTP`,
     and others honour these without any image cooperation.

  2. **System-bundle overlay** for tools that read the OS trust
     store directly. The sandbox synthesises a bundle that is the
     Mozilla public CA list plus the per-session CA (assembled by
     `Condukt.Sandbox.Net.CA.trust_bundle/1` from the snapshot
     shipped under `priv/ca-certificates/mozilla.pem`) and mounts it
     via `subPath` at `/etc/ssl/certs/ca-certificates.crt` and
     `/etc/ssl/cert.pem`. Those are the two paths every mainstream
     Linux distro and distroless image use, so static Go binaries,
     OpenSSL CLI tools, and any client falling back to the system
     bundle see Mozilla's roots plus the session CA at the location
     they already expect.

Between the two paths there is no image preparation step. Operators
point `:image` at whatever they were already using (`debian:bookworm-slim`,
`python:3.13-slim`, `node:20-bookworm`, an internal base, a distroless
runtime) and `Sandbox.Net` works.

The one stack still not addressed is Java. JVM HTTPS clients read a
JKS truststore, not PEM files. If you need JVM cooperation, install
the CA into the JVM keystore at image build time.

## Sandbox support

| Sandbox       | Net support              |
| ------------- | ------------------------ |
| `Local`       | Not supported. No reliable enforcement plane on the host. |
| `Virtual`     | Not yet. Will hook into the same layer at the Rust boundary when bashkit gains a network surface. |
| `Kubernetes`  | Supported via the egress sidecar. |

Sandboxes that do not support net silently ignore the `:net` option so
agent definitions stay portable across backends.

## Limitations

  * **Mixed-protocol h2/h1** connections (client picks one, upstream
    only offers the other) fall back to byte splice for that
    connection. Body capture degrades to bytes-only for that request.
  * **Non-HTTP TLS** flows through correctly at the TCP layer but
    method/path/header capture expects HTTP framing.
  * **Egress to ports other than 80/443** is denied at the
    NetworkPolicy layer but not surfaced as a telemetry event.

## RBAC

In addition to the existing pod / pods/exec verbs the Kubernetes
sandbox needs, `:net` requires the cluster identity to create and
delete `secrets` and `networkpolicies` in the target namespace:

```yaml
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "create", "delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: ["get", "create", "delete"]
```

See `guides/sandbox.md` for the base RBAC bundle.

## Images

The `condukt-egress` sidecar image is published to
`ghcr.io/tuist/condukt-egress:<version>` on every Condukt release.
`Condukt.Sandbox.Net.K8s.Manifests.default_image/0` resolves to the
tag matching the installed Condukt version. Override with the `:image`
key on `:net` opts when mirroring or pinning.

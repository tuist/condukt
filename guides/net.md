# Sandbox Net

`Condukt.Sandbox.Net` captures every outbound HTTP request an agent
makes inside a sandbox, surfaces it as a structured event, and enforces
per-request policy at the network layer. It is the egress counterpart
to `Condukt.Sandbox`'s filesystem and process capture.

The sidecar terminates TLS for every outbound HTTPS connection using a
per-session ephemeral CA, then forwards the request to the real
destination. Method, path, headers, and body all land in the event
stream. Cleartext HTTP (port 80) is captured at the wire layer directly.

The workspace image must trust the per-session CA at session start.
Operators either build a cooperative image from any base with
`mix condukt.workspace.prepare`, or `FROM` one of the published
`ghcr.io/tuist/condukt-workspace:*` images. Without a trusted CA the
TLS handshake fails and the request emits a `request_closed` event
with reason `tls_handshake_failed`; the request does not flow.

## Quick start

```elixir
defmodule MyApp.CodingAgent do
  use Condukt

  @impl true
  def sandbox do
    {
      Condukt.Sandbox.Kubernetes,
      namespace: "agents",
      image: "ghcr.io/myorg/agent:1.4-condukt",
      net: [
        policy: %Condukt.Sandbox.Net.Policy{
          allow_hosts: ["api.github.com", "*.openai.com"],
          decide: {MyApp.NetGuard, timeout: 5_000},
          sink: {Condukt.Sandbox.Net.Sink.Process, to: MyApp.NetEventListener}
        }
      ]
    }
  end
end
```

When the session starts, Condukt:

1. Generates a per-session ephemeral CA (ECDSA P-256, 24h validity).
2. Creates a Kubernetes `Secret` carrying the policy JSON + CA cert
   (+ key) labelled with the session id.
3. Creates a `NetworkPolicy` that restricts pod egress to DNS and the
   sidecar's outbound dials.
4. Adds the `condukt-egress` init container (writes iptables rules)
   and sidecar container (transparent proxy + control channel) to the
   pod.
5. The init container's iptables redirect routes the workspace's
   tcp/80 + tcp/443 traffic into the sidecar regardless of what's
   inside the workspace image.

Events flow into the configured `:sink` as
`%Condukt.Sandbox.Net.Event{}` structs.

## Policy

```elixir
%Condukt.Sandbox.Net.Policy{
  allow_hosts: ["api.github.com", "*.openai.com", "**.googleapis.com"],
  deny_hosts: ["secret.internal.example.com"],
  decide: {MyApp.NetGuard, timeout: 5_000},
  default: :deny,
  redact: [~r/sk-[A-Za-z0-9]{32,}/],
  max_body_capture: 4096,
  sink: {Condukt.Sandbox.Net.Sink.Process, to: self()}
}
```

For each outbound connection the sidecar parses the SNI (HTTPS) or
`Host:` header (HTTP) and looks the hostname up through this pipeline:

1. **`deny_hosts`** — if the host matches, deny immediately. Evaluated
   first so a deny is always final.
2. **`allow_hosts`** — if the host matches, allow immediately. No
   round-trip to the BEAM, no LLM cost. Use for hostnames you trust
   unconditionally for this session.
3. **`decide`** — if set, the request and a session-context snapshot
   are sent to the configured decider (function, MFA tuple, or
   `Condukt` agent module). The decider returns `:allow` or
   `{:deny, reason}`. If the decider times out (default 5s), the
   default action applies. Use for hostnames you want a human or an
   agent to gate on.
4. **`default`** — `:allow` or `:deny`. Applied when none of the
   above matched. Defaults to `:deny` so the policy fails closed.

Host patterns:

  * `api.github.com` matches the literal hostname.
  * `*.openai.com` matches one DNS label before the literal suffix
    (matches `api.openai.com` but not `v1.api.openai.com`).
  * `**.googleapis.com` matches one or more labels.

## Decider

A decider is a callable that, given a session-context snapshot and a
parsed request, returns `:allow | {:deny, reason}`. Three forms are
supported.

### Function

```elixir
decide: fn ctx, req ->
  if String.contains?(req.host, "internal") do
    {:deny, "internal hosts blocked"}
  else
    :allow
  end
end
```

Synchronous, programmatic. Runs in the BEAM's normal scheduler with no
LLM cost. Suited to rules that can be expressed in code.

### MFA tuple

```elixir
decide: {MyApp.NetGuard, :decide, []}
```

Same shape as the function form but referenceable from configuration.

### Agent module

```elixir
decide: {MyApp.NetGuard, timeout: 10_000}

defmodule MyApp.NetGuard do
  use Condukt

  @impl true
  def model, do: "anthropic:claude-sonnet-4-6"

  @impl true
  def system_prompt do
    """
    You gate outbound network requests for an AI coding agent.
    You receive the request the agent is about to make and a few
    messages of context. Decide whether the request fits the
    session's stated purpose and whether the destination is safe.
    Return JSON `{"decision": "allow" | "deny", "reason": "..."}`.
    """
  end

  @impl true
  def output_schema do
    %{
      type: "object",
      properties: %{
        decision: %{type: "string", enum: ["allow", "deny"]},
        reason: %{type: "string"}
      },
      required: ["decision", "reason"]
    }
  end
end
```

The agent runs as a sub-agent of the gated session. It receives the
session-context snapshot and the request as JSON input. Its structured
output is decoded into a decision. If the agent errors or its output
fails schema validation, the request is denied with `:decider_error`.

The decider agent's own egress is **not** routed through the same
sandbox-net policy: gating the gatekeeper's calls through itself would
deadlock. Run the decider with a different `Condukt.Sandbox.Net.Policy`
(or with `:net` unset) if it needs to make API calls of its own.

### Context snapshot

The decider receives a `Condukt.Sandbox.Net.Context` containing:

  * `:session_id` — the gated session's id.
  * `:recent_messages` — the last N messages from the session
    (default `5`, configurable via `Policy.context_messages`).
    Redaction (`Condukt.Redactor`) is applied to message bodies
    before they leave the session.
  * `:request` — the `Condukt.Sandbox.Net.Request` the agent is about
    to make. Method, path, and headers are populated where the
    sidecar could derive them; full body is not in the context (only
    method/path/headers, to keep the decider cost bounded).
  * `:metadata` — caller-supplied per-session metadata, set on the
    sandbox spec via `net: [..., context_metadata: %{...}]`. Useful
    for passing in user identity, tenant, or session purpose.

### Timeouts

If the decider does not respond within `:timeout` (default 5000ms),
the request is denied with reason `:decider_timeout`. The sidecar
closes the connection; the workspace sees a normal connection reset.

### Decision caching

A per-session in-memory cache (keyed on host) coalesces identical
decisions for the duration of the session. A decider that says "deny
github.com" once does not get re-invoked for every subsequent
github.com connection. To disable, pass `decision_cache: false` on the
policy.

## Sinks

Events are delivered to whichever sink the policy declares.

  * `Condukt.Sandbox.Net.Sink.Log` (default) emits a `Logger.info/1`
    line and a `[:condukt, :sandbox, :net, kind]` telemetry event.
  * `Condukt.Sandbox.Net.Sink.Process` forwards events to a target
    `pid()` or registered atom as
    `{:condukt_sandbox_net_event, event}` messages.
  * Any module implementing the `Condukt.Sandbox.Net.Sink` behaviour.

## Cooperative workspace images

The workspace image needs to trust the per-session CA.
`mix condukt.workspace.prepare` derives a cooperative variant from any
base image:

```
mix condukt.workspace.prepare node:20-bookworm \
  --output ghcr.io/acme/agent:1.4-condukt \
  --push
```

The derived image adds `ca-certificates`, environment variables for
runtimes that ignore the system trust store (`NODE_EXTRA_CA_CERTS`,
`REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, `PIP_CERT`, `CURL_CA_BUNDLE`,
`GIT_SSL_CAINFO`), and an entrypoint shim that installs the mounted CA
at session start.

## Sandbox support

| Sandbox       | Net support              |
| ------------- | ------------------------ |
| `Local`       | Not supported. No reliable enforcement plane on the developer's host without privileged setup. |
| `Virtual`     | Not yet (bashkit has no network surface today). |
| `Kubernetes`  | Supported with a cooperative workspace image. |

Sandboxes that do not support net silently ignore the `:net` option so
agent definitions stay portable across backends.

## Limitations

  * **Mixed-protocol h2/h1** — the proxy advertises both `h2` and
    `http/1.1` via ALPN. When client and upstream agree, body capture
    works at the agreed protocol. When they disagree the connection
    forwards bytes opaquely (no head capture). In practice this is
    rare because modern servers offer both.
  * **Non-HTTP TLS** — raw gRPC over h2c, custom protocols inside
    TLS — the TLS handshake still succeeds and the connection
    forwards, but body capture expects HTTP framing inside the
    tunnel.
  * **Egress to ports other than 80/443** is denied at the
    NetworkPolicy layer but not surfaced as a `Net.Event`. If you
    need other ports proxied, request them on the `:net` opt; a future
    revision will accept a list of redirected ports.

## RBAC

In addition to the existing pod / pods/exec verbs the Kubernetes
sandbox needs, enabling `:net` requires the cluster identity to be
able to create and delete `secrets` and `networkpolicies` in the
target namespace:

```yaml
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "create", "delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: ["get", "create", "delete"]
```

See `guides/sandbox.md` for the base RBAC bundle and combine the two.

## Telemetry

The default sink emits one telemetry event per request kind:

```
[:condukt, :sandbox, :net, :request_opened]
[:condukt, :sandbox, :net, :request_allowed]
[:condukt, :sandbox, :net, :request_denied]
[:condukt, :sandbox, :net, :request_closed]
```

Measurements: `%{bytes_in: integer, bytes_out: integer}`.
Metadata: `%{request: Condukt.Sandbox.Net.Request.t(), reason: atom() | binary() | nil}`.

## Images

The `condukt-egress` sidecar image is published to
`ghcr.io/tuist/condukt-egress:<version>` (and `:latest`) on every
Condukt release. By default `Condukt.Sandbox.Net.K8s.Manifests` pulls
the tag that matches the installed Condukt version. Override with the
`:image` key on the `:net` opts if you mirror the image internally or
need to pin to a different version.

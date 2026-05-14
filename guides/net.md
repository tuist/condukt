# Sandbox Net

`Condukt.Sandbox.Net` captures every outbound TCP connection an agent
makes inside a sandbox, surfaces it as a structured event, and enforces
per-host policy at the network layer. It is the egress counterpart to
`Condukt.Sandbox`'s filesystem and process capture.

Two capture tiers are supported:

| Tier | What you see | Image requirement | Enforcement |
|------|--------------|-------------------|-------------|
| 1    | TLS SNI, destination IP/port, byte counts | None: any image works | RST at SNI on deny |
| 2    | Tier 1 + method, path, headers | Image trusts the per-session CA | Same |

Tier 1 always works as soon as the sandbox is `Condukt.Sandbox.Kubernetes`
and a `:net` policy is configured. Tier 2 additionally requires the
workspace image to trust a per-session CA that Condukt generates and
mounts at session start. The `mix condukt.workspace.prepare` task
derives a cooperative variant from any image so operators don't have
to maintain their own Dockerfile for this.

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
          allow_hosts: ["api.github.com", "*.openai.com"],
          default: :deny,
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
`%Condukt.Sandbox.Net.Event{}` structs (one per connection lifecycle
step).

## How the redirect works

`condukt-egress netfilter-setup` runs once as an init container (with
`CAP_NET_ADMIN`) and writes these rules into the pod's network
namespace:

```
iptables -t nat -A OUTPUT -o lo -j RETURN
iptables -t nat -A OUTPUT -m owner --uid-owner <sidecar-uid> -j RETURN
iptables -t nat -A OUTPUT -p tcp --dport 80  -j REDIRECT --to-port 15001
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 15001
```

Loopback and the sidecar's own traffic are exempted. Everything else
heading out to ports 80 or 443 gets rewritten in the kernel to land on
`localhost:15001`, where the sidecar listens. Because the rewrite is
kernel-side, it does not matter whether the agent uses `curl`, `git`,
`npm`, a static Go binary with its own TLS stack, or anything else.
The agent's container is created without `CAP_NET_ADMIN`, so it cannot
remove these rules.

## What the sidecar does

For each redirected connection the sidecar:

1. Recovers the original destination via `SO_ORIGINAL_DST`.
2. Peeks the first bytes to identify TLS (ClientHello byte pattern)
   or cleartext HTTP (`Host:` header).
3. Pulls the destination hostname out of either the SNI extension or
   the `Host:` header, falling back to the destination IP.
4. Evaluates the hostname against the policy. On deny, it RSTs the
   connection and emits a `request_denied` event.
5. On allow, depending on tier:
   - **Tier 1**: opens a TCP connection to the original destination
     and splices bytes between client and upstream. Bodies remain
     opaque.
   - **Tier 2** (if a CA is configured AND the connection is TLS):
     mints a leaf certificate for the SNI host signed by the
     per-session CA, terminates TLS to the client using that leaf,
     opens a fresh outbound TLS connection to the real upstream
     (verifying the upstream cert against the system trust store),
     parses the HTTP/1.1 request line + headers, and forwards the
     traffic. Method, path, and headers land in the event.
6. On connection close, emits a `request_closed` event with
   `bytes_in` / `bytes_out` and `finished_at`.

## Policy

```elixir
%Condukt.Sandbox.Net.Policy{
  allow_hosts: ["api.github.com", "*.openai.com", "**.googleapis.com"],
  deny_hosts: ["secret.internal.example.com"],
  default: :deny,
  redact: [~r/sk-[A-Za-z0-9]{32,}/],
  max_body_capture: 4096,
  sink: {Condukt.Sandbox.Net.Sink.Process, to: self()}
}
```

Host patterns:

  * `api.github.com` matches the literal hostname.
  * `*.openai.com` matches one DNS label before the literal suffix
    (matches `api.openai.com` but not `v1.api.openai.com`).
  * `**.googleapis.com` matches one or more labels.

`:deny_hosts` is evaluated before `:allow_hosts`. The default action
applies when neither list matches; setting `default: :deny` (the
factory default) makes the policy fail closed.

## Sinks

Events are delivered to whichever sink the policy declares.

  * `Condukt.Sandbox.Net.Sink.Log` (default) emits a `Logger.info/1`
    line and a `[:condukt, :sandbox, :net, kind]` telemetry event.
  * `Condukt.Sandbox.Net.Sink.Process` forwards events to a target
    `pid()` or registered atom as
    `{:condukt_sandbox_net_event, event}` messages. Useful for tests
    and applications that already own an event-handling process.
  * Any module implementing the `Condukt.Sandbox.Net.Sink` behaviour.

## Tier 2: making a workspace image cooperative

For body capture the workspace image needs to trust the per-session
CA. `mix condukt.workspace.prepare` derives a cooperative variant
from any base image:

```
mix condukt.workspace.prepare node:20-bookworm \
  --output ghcr.io/acme/agent:1.4-condukt \
  --push
```

The derived image adds:

  * `ca-certificates` (auto-detected across Debian/Alpine/RHEL).
  * Env vars for runtimes that ignore the system trust store:
    `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`,
    `PIP_CERT`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`.
  * An entrypoint shim that installs the mounted CA at
    `/etc/condukt/ca.pem` into the system trust store at container
    start, then `exec`s into the original `CMD`.

If the base image had a non-trivial `ENTRYPOINT`, pass
`--preserve-entrypoint "/path/to/it"` and the shim will exec into it
after the install step.

If an operator skips the `prepare` step, Tier 1 still works on the
unmodified image; only the body inspection is unavailable.

## Sandbox support

| Sandbox       | Net support              |
| ------------- | ------------------------ |
| `Local`       | Not supported. No reliable enforcement plane on the developer's host without privileged setup. |
| `Virtual`     | Not yet (bashkit has no network surface today). The API will route through the NIF when bashkit gains net. |
| `Kubernetes`  | Tier 1 always; Tier 2 with cooperative images. |

Sandboxes that do not support net silently ignore the `:net` option so
agent definitions stay portable across backends.

## Limitations

  * **HTTP/2 mixed-protocol** connections fall back to byte-splice.
    The proxy advertises both `h2` and `http/1.1` via ALPN. When
    client and upstream negotiate the same protocol, body capture
    works; when they negotiate different protocols (e.g. client picks
    h2, upstream only does h1), the proxy falls through to the
    Tier-1 splice path for that connection. In practice this is
    extremely rare because modern servers offer both.
  * **Non-HTTP TLS** (raw gRPC over h2c, custom protocols inside
    TLS) flows through Tier 1 correctly (SNI audit + host policy)
    but Tier 2 body capture expects HTTP framing inside the TLS
    tunnel.
  * **Egress to ports other than 80/443** bypasses the proxy because
    the iptables redirect only covers those two ports. The
    NetworkPolicy denies them at the CNI layer instead, but the
    decision is not surfaced as a `Net.Event`. If you need other
    ports proxied, request them on the `:net` opt: a future revision
    will accept a list of redirected ports.
  * **BEAM-side event subscription** is not wired yet: the sidecar
    emits NDJSON events over its control TCP channel, and
    `Condukt.Sandbox.Net.K8s.ControlReader` decodes them, but the
    K8s port-forward connecting the two has not landed. Until that
    closes, events are visible via the sidecar's container logs (and
    are deliverable to any caller that opens a port-forward to
    `:15002` on the pod). The wire format is stable.

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
the tag that matches the installed Condukt version, so a Hex consumer
of v1.5.0 automatically pulls
`ghcr.io/tuist/condukt-egress:1.5.0`. Override with the `:image` key
on the `:net` opts if you mirror the image internally or need to pin
to a different version.

defmodule Condukt.Sandbox.Net do
  @moduledoc """
  Outbound network audit and policy for sandboxes.

  `Sandbox.Net` is the BEAM-side counterpart to the `condukt-egress` sidecar
  that runs alongside `Condukt.Sandbox.Kubernetes` pods. It captures every
  outbound TCP connection the agent makes, surfaces it as a structured event,
  and enforces host-level allow/deny policy at the network layer.

  Two capture tiers are supported:

    * **Tier 1 (any image)** — the sidecar reads the TLS SNI, original
      destination, and byte counts. Works on any workspace image, including
      ones the operator did not build. Body inspection is unavailable; host
      allowlists are fully enforced. See `guides/net.md` for details.
    * **Tier 2 (cooperative image)** — the sidecar terminates TLS with a
      per-session CA. Method, path, headers, and body are captured (subject
      to `Condukt.Sandbox.Net.Policy` redaction). Requires the workspace
      image to trust the per-session CA, which `mix condukt.workspace.prepare`
      bakes in.

  ## Configuring

  Attach a policy when configuring the sandbox:

      sandbox: {
        Condukt.Sandbox.Kubernetes,
        net: %Condukt.Sandbox.Net.Policy{
          allow_hosts: ["api.github.com", "*.openai.com"],
          default: :deny,
          sink: {Condukt.Sandbox.Net.Sink.Process, to: self()}
        }
      }

  Events flow into the configured sink as
  `Condukt.Sandbox.Net.Event` structs.

  ## Sandbox support

  | Sandbox       | Net support              |
  | ------------- | ------------------------ |
  | `Local`       | Not supported (no enforcement plane on the host) |
  | `Virtual`     | Not yet (bashkit has no network surface today)   |
  | `Kubernetes`  | Tier 1 always; Tier 2 with cooperative images    |

  Sandboxes that do not support net silently ignore the `:net` option so
  agent definitions stay portable across backends.
  """

  alias Condukt.Sandbox.Net.{Event, Policy, Request, Sink}

  @doc """
  Evaluates a request against a policy and emits the resulting event.

  Returns `:allow` or `{:deny, reason}`. The caller is responsible for
  using the result to actually open or refuse the connection (in the K8s
  path, the sidecar does this; this function is the BEAM-side
  reflection for cases where the BEAM is the policy authority).
  """
  def evaluate(%Policy{} = policy, %Request{host: host}) do
    Policy.evaluate(policy, host)
  end

  @doc """
  Builds and delivers an event to the policy's sink.

  This is the canonical entry point used by the K8s sandbox after decoding
  an NDJSON event from the egress sidecar.
  """
  def deliver(policy, kind, %Request{} = request, opts \\ []) do
    event = Event.new(kind, request, opts)
    sink = if policy, do: policy.sink, else: Condukt.Sandbox.Net.Sink.Log
    Sink.deliver(sink, event)
  end
end

defmodule Condukt.Sandbox.Net do
  @moduledoc """
  Outbound network audit and policy for sandboxes.

  `Sandbox.Net` is the BEAM-side counterpart to the `condukt-egress` sidecar
  that runs alongside `Condukt.Sandbox.Kubernetes` pods. It captures every
  outbound HTTP request the agent makes, surfaces it as a structured event,
  and enforces per-request policy at the network layer.

  The sidecar terminates TLS for every outbound HTTPS connection using a
  per-session ephemeral CA, then forwards the request to the real
  destination. Method, path, headers, and body land in the
  `Condukt.Sandbox.Net.Event` delivered to the configured sink. The
  workspace image must trust the per-session CA at session start: use
  `mix condukt.workspace.prepare <image>` to derive a cooperative variant
  from any base image, or `FROM` one of the published
  `ghcr.io/tuist/condukt-workspace:*` images.

  ## Configuring

  Attach a policy when configuring the sandbox:

      sandbox: {
        Condukt.Sandbox.Kubernetes,
        net: %Condukt.Sandbox.Net.Policy{
          allow_hosts: ["api.github.com", "*.openai.com"],
          decide: {MyApp.NetGuard, timeout: 5_000},
          sink: {Condukt.Sandbox.Net.Sink.Process, to: self()}
        }
      }

  Events flow into the configured sink as `Condukt.Sandbox.Net.Event`
  structs.

  ## Sandbox support

  | Sandbox       | Net support              |
  | ------------- | ------------------------ |
  | `Local`       | Not supported (no enforcement plane on the host) |
  | `Virtual`     | Not yet (bashkit has no network surface today)   |
  | `Kubernetes`  | Supported with a cooperative workspace image     |

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

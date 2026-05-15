defmodule Condukt.Sandbox.Net do
  @moduledoc """
  Outbound network audit and policy for sandboxes.

  `Sandbox.Net` is the BEAM-side counterpart to the `condukt-egress`
  sidecar that runs alongside `Condukt.Sandbox.Kubernetes` pods. It
  captures every outbound HTTP request the agent makes, surfaces it as
  a structured event over telemetry, and enforces per-request policy at
  the network layer.

  See `Condukt.Sandbox.Net.Policy` for the rules pipeline and
  `guides/net.md` for the full picture, including the deployment-side
  pieces (CA, sidecar, NetworkPolicy) and the decider model.

  ## Telemetry

  Every request lifecycle step emits one of:

    * `[:condukt, :sandbox, :net, :request_opened]` — first byte from the
      workspace reached the sidecar.
    * `[:condukt, :sandbox, :net, :request_allowed]` — policy passed,
      sidecar is forwarding to the upstream.
    * `[:condukt, :sandbox, :net, :request_denied]` — policy refused
      the connection. Metadata `:reason` carries the rule outcome.
    * `[:condukt, :sandbox, :net, :request_closed]` — connection ended
      (clean or otherwise). Final byte counts are in `measurements`.

  Measurements: `%{bytes_in: integer, bytes_out: integer}`. Metadata:
  `%{request: Condukt.Sandbox.Net.Request.t(), reason: atom() | binary() | nil}`.

  Attach a handler with `:telemetry.attach/4` to ship these into your
  existing observability stack.

  ## Sandbox support

  | Sandbox       | Net support              |
  | ------------- | ------------------------ |
  | `Local`       | Not supported (no enforcement plane on the host) |
  | `Virtual`     | Not yet (bashkit has no network surface today)   |
  | `Kubernetes`  | Supported via the egress sidecar |

  Sandboxes that do not support net silently ignore the `:net` option
  so agent definitions stay portable across backends.
  """

  alias Condukt.Sandbox.Net.Policy
  alias Condukt.Sandbox.Net.Request

  @doc """
  Evaluates a request against a policy's rule pipeline. Returns
  `:allow` or `{:deny, reason}`.

  This is the BEAM-side reflection of what the sidecar runs locally.
  Useful in tests or when the BEAM is the policy authority for a
  non-K8s code path.
  """
  def evaluate(%Policy{} = policy, %Request{} = request) do
    Policy.evaluate(policy, %Condukt.Sandbox.Net.Context{request: request}, request)
  end

  @doc """
  Emits a telemetry event for a request lifecycle step.

  Called by the K8s control bridge when an NDJSON frame arrives from
  the sidecar. The kind atom names the lifecycle step
  (`:request_opened`, `:request_allowed`, `:request_denied`,
  `:request_closed`). `opts` accepts `:reason` (a deny reason or any
  free-form string) and `:at` (a timestamp; unused for telemetry,
  surfaced through metadata).
  """
  def deliver(_policy, kind, %Request{} = request, opts \\ []) do
    reason = Keyword.get(opts, :reason)

    :telemetry.execute(
      [:condukt, :sandbox, :net, kind],
      %{bytes_in: request.bytes_in, bytes_out: request.bytes_out},
      %{request: request, reason: reason}
    )

    :ok
  end
end

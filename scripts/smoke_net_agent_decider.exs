# End-to-end smoke for the `Condukt.Sandbox.NetworkPolicy.AgentDecider` form.
#
# Same kind cluster setup as `smoke_net.exs`. The difference: the
# policy's `:decide` rule points at `AgentDecider` wrapping a native
# Condukt agent. When the workspace makes an HTTPS request to a host
# not in the static allowlist, the sidecar emits `decision_request`,
# the bridge invokes the agent, the agent's structured output (a
# schema injected by AgentDecider, not described in the prompt)
# decides allow/deny, and the decision flows back through the wire.
#
# Prereqs (same as smoke_net.exs) plus:
#
#   - A model API key available to the native runtime (e.g.
#     `ANTHROPIC_API_KEY`), since structured output runs the native
#     tool loop.
#
# Usage:
#
#   mix run scripts/smoke_net_agent_decider.exs

Mix.start()
Application.ensure_all_started(:k8s)
Application.ensure_all_started(:logger)

# Small native Condukt agent that decides whether to allow a network
# request. AgentDecider injects the decision output schema, so the
# system prompt only describes the policy, not a wire format.
defmodule SmokeAgent.NetGuard do
  use Condukt

  @impl true
  def system_prompt do
    """
    You are gating outbound network requests for an AI coding agent.
    You receive the request and recent session context.

    Allow well-known reputable API hosts (github.com, openai.com,
    anthropic.com, googleapis.com, cloudflare.com). Deny anything else.
    """
  end
end

alias Condukt.Sandbox.NetworkPolicy
alias Condukt.Sandbox.NetworkPolicy.AgentDecider

policy = %NetworkPolicy{
  rules: [
    allow: ["api.github.com"],
    decide: [call: {AgentDecider, agent: SmokeAgent.NetGuard}, timeout: 30_000]
  ],
  default: :deny
}

session_id = "agent-smoke-" <> (System.unique_integer([:positive]) |> Integer.to_string())
namespace = "default"

{:ok, conn} =
  K8s.Conn.from_file(Path.expand("~/.kube/config"), context: "kind-condukt-net-smoke")

IO.puts("==> Initialising Sandbox.Kubernetes session_id=#{session_id}")

{:ok, state} =
  Condukt.Sandbox.Kubernetes.init(
    id: session_id,
    namespace: namespace,
    image: "curlimages/curl:8.10.1",
    cwd: "/home/curl_user",
    conn: conn,
    ready_timeout: 120_000,
    heartbeat_interval: false,
    network_policy: policy,
    network_policy_image: "condukt-egress:smoke"
  )

IO.puts("==> Pod up: #{state.pod_name}")
Process.sleep(2_000)

exec_curl = fn host ->
  argv = [
    "--context",
    "kind-condukt-net-smoke",
    "-n",
    namespace,
    "exec",
    state.pod_name,
    "-c",
    "agent",
    "--",
    "curl",
    "-svo",
    "/dev/null",
    "-m",
    "45",
    "--cacert",
    "/etc/condukt/ca.pem",
    "https://" <> host
  ]

  System.cmd("kubectl", argv, stderr_to_stdout: true)
end

run_case = fn host ->
  IO.puts("\n==> #{host}")
  before = System.monotonic_time(:millisecond)
  {out, exit} = exec_curl.(host)
  duration = System.monotonic_time(:millisecond) - before

  outcome =
    cond do
      exit == 0 -> :allowed
      String.contains?(out, "SSL_ERROR_SYSCALL") -> :denied_or_failed
      true -> :other
    end

  IO.puts("    exit=#{exit} duration=#{duration}ms outcome=#{outcome}")
  outcome
end

# Test 1: a reputable host the decider should allow.
allow_outcome = run_case.("api.openai.com")

# Test 2: a non-reputable host the decider should deny.
deny_outcome = run_case.("example.org")

IO.puts("\n==> teardown")
Condukt.Sandbox.Kubernetes.shutdown(state)

IO.puts("\n=== summary ===")
IO.puts("api.openai.com -> #{allow_outcome} (expected :allowed)")
IO.puts("example.org    -> #{deny_outcome} (expected :denied_or_failed)")

if allow_outcome == :allowed and deny_outcome == :denied_or_failed do
  IO.puts("\nAgentDecider smoke PASSED")
  System.halt(0)
else
  IO.puts("\nAgentDecider smoke FAILED")
  System.halt(1)
end

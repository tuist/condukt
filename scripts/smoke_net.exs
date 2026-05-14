# Smoke test for `Condukt.Sandbox.Net` end-to-end against a kind cluster.
#
# Prereqs:
#
#   - `kind` cluster named `condukt-net-smoke` already created and the
#     `condukt-egress:smoke` image loaded into it
#   - workspace image `curlimages/curl:8.10.1` loaded into the cluster
#   - `~/.kube/config` points at the kind context
#
# Usage:
#
#   mix run scripts/smoke_net.exs
#
# What it checks:
#
#   1. The Condukt.Sandbox.Net.K8s integration applies a Secret +
#      NetworkPolicy + augmented pod spec to the cluster.
#   2. The pod's init container (`condukt-net-init`) runs the iptables
#      rules and exits 0.
#   3. The sidecar container (`condukt-net-egress`) starts and reports
#      "accepting connections" in its logs.
#   4. With the CA trusted in the workspace, `curl --cacert .../ca.pem
#      https://api.github.com` succeeds (MITM is transparent).
#   5. A request to a host outside the allowlist is RST at SNI by the
#      sidecar (deny event surfaces in logs).
#   6. Without --cacert the TLS handshake fails (request_closed event
#      with reason tls_handshake_failed); no fallback path exists.
#
# Tear-down is automatic (delete_on_shutdown derives from generated
# id), but feel free to `kubectl delete pod -l condukt.tuist.dev/id=...`
# if anything sticks around.

Mix.start()
Application.ensure_all_started(:k8s)
Application.ensure_all_started(:logger)

alias Condukt.Sandbox.Net.Policy

session_id = "smoke-" <> (System.unique_integer([:positive]) |> Integer.to_string())
namespace = "default"

kubeconfig = Path.expand("~/.kube/config")

{:ok, conn} =
  K8s.Conn.from_file(kubeconfig, context: "kind-condukt-net-smoke")

policy = %Policy{
  allow_hosts: ["api.github.com", "example.com"],
  default: :deny,
  sink: self()
}

IO.puts("==> Initialising Sandbox.Kubernetes session_id=#{session_id} ns=#{namespace}")

start_result =
  Condukt.Sandbox.Kubernetes.init(
    id: session_id,
    namespace: namespace,
    image: "curlimages/curl:8.10.1",
    cwd: "/home/curl_user",
    conn: conn,
    ready_timeout: 120_000,
    heartbeat_interval: false,
    net: [
      policy: policy,
      image: "condukt-egress:smoke"
    ]
  )

case start_result do
  {:ok, state} ->
    IO.puts("==> Pod up: #{state.pod_name}")

    # Give the init container time to apply iptables; check it ran by
    # tailing its logs.
    init_logs =
      System.cmd("kubectl", [
        "--context",
        "kind-condukt-net-smoke",
        "-n",
        namespace,
        "logs",
        state.pod_name,
        "-c",
        "condukt-net-init"
      ])
      |> elem(0)

    IO.puts("---- init container logs ----")
    IO.puts(init_logs)

    sidecar_logs =
      System.cmd("kubectl", [
        "--context",
        "kind-condukt-net-smoke",
        "-n",
        namespace,
        "logs",
        state.pod_name,
        "-c",
        "condukt-net-egress"
      ])
      |> elem(0)

    IO.puts("---- sidecar logs ----")
    IO.puts(sidecar_logs)

    if String.contains?(sidecar_logs, "accepting connections") do
      IO.puts("==> sidecar proxy is running")
    else
      IO.puts("XX  sidecar did not reach 'accepting connections'")
    end

    exec_curl = fn args ->
      kubectl_argv =
        [
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
          "10"
        ] ++ args

      System.cmd("kubectl", kubectl_argv, stderr_to_stdout: true)
    end

    # Test 1: cooperative path. The workspace trusts the mounted CA so
    # the MITM handshake succeeds and we see the HTTP/2 response.
    IO.puts("==> allow + trust: curl --cacert /etc/condukt/ca.pem https://api.github.com")
    {allow_out, allow_exit} = exec_curl.(["--cacert", "/etc/condukt/ca.pem", "https://api.github.com"])
    IO.puts(allow_out)
    IO.puts("    exit=#{allow_exit}")

    # Test 2: deny path. example.org isn't in the allowlist; the
    # sidecar should refuse at SNI before terminating TLS.
    IO.puts("==> deny: curl --cacert /etc/condukt/ca.pem https://example.org")
    {deny_out, deny_exit} = exec_curl.(["--cacert", "/etc/condukt/ca.pem", "https://example.org"])
    IO.puts(deny_out)
    IO.puts("    exit=#{deny_exit}")

    # Test 3: uncooperative workspace. Without --cacert curl rejects
    # the leaf cert; we expect a request_closed event with reason
    # tls_handshake_failed in the sidecar logs.
    IO.puts("==> handshake fail (no cacert): curl https://api.github.com")
    {fail_out, fail_exit} = exec_curl.(["https://api.github.com"])
    IO.puts(fail_out)
    IO.puts("    exit=#{fail_exit}")

    # Tail sidecar logs after the curl to see request_opened events
    {after_logs, _} =
      System.cmd("kubectl", [
        "--context",
        "kind-condukt-net-smoke",
        "-n",
        namespace,
        "logs",
        state.pod_name,
        "-c",
        "condukt-net-egress"
      ])

    IO.puts("---- sidecar logs after curl ----")
    IO.puts(after_logs)

    IO.puts("==> teardown")
    Condukt.Sandbox.Kubernetes.shutdown(state)

  {:error, reason} ->
    IO.puts("XX  sandbox init failed: #{inspect(reason)}")
    System.halt(1)
end

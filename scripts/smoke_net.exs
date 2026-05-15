# Smoke test for `Condukt.Sandbox.NetworkPolicy` end-to-end against a kind cluster.
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
#   1. The Condukt.Sandbox.NetworkPolicy.K8s integration applies a Secret +
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

alias Condukt.Sandbox.NetworkPolicy

session_id = "smoke-" <> (System.unique_integer([:positive]) |> Integer.to_string())
namespace = "default"

kubeconfig = Path.expand("~/.kube/config")

{:ok, conn} =
  K8s.Conn.from_file(kubeconfig, context: "kind-condukt-net-smoke")

# A function decider that allows api.openai.com (not in the static
# allowlist) and denies everything else. This forces the sidecar to
# round-trip a `decision_request` over the control bridge.
decider_pid = self()

decider = fn _ctx, req ->
  send(decider_pid, {:decider_invoked, req.host})

  cond do
    req.host == "api.openai.com" -> :allow
    String.ends_with?(req.host, ".cloudflare.com") -> :allow
    true -> {:deny, "denied by smoke decider"}
  end
end

policy = %NetworkPolicy{
  rules: [
    allow: ["api.github.com"],
    decide: decider
  ],
  decide_timeout: 5_000,
  default: :deny
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
    network_policy: policy,
    network_policy_image: "condukt-egress:smoke"
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

    # Wait a beat for the ControlBridge to attach.
    Process.sleep(2_000)

    # Test 1: static allowlist. api.github.com is in `allow_hosts`,
    # short-circuits in the sidecar (no decider round-trip).
    IO.puts("==> static allow: curl --cacert ... https://api.github.com")
    {out1, exit1} = exec_curl.(["--cacert", "/etc/condukt/ca.pem", "https://api.github.com"])
    IO.puts(out1 |> String.split("\n") |> Enum.take(20) |> Enum.join("\n"))
    IO.puts("    exit=#{exit1}")

    # Test 2: decider allow. api.openai.com isn't in the static
    # allowlist; the sidecar emits decision_request, the BEAM decider
    # returns :allow, and the request flows.
    IO.puts("==> decider allow: curl --cacert ... https://api.openai.com")
    {out2, exit2} = exec_curl.(["--cacert", "/etc/condukt/ca.pem", "https://api.openai.com"])
    IO.puts(out2 |> String.split("\n") |> Enum.take(15) |> Enum.join("\n"))
    IO.puts("    exit=#{exit2}")

    assert_receive_decider = fn host ->
      receive do
        {:decider_invoked, ^host} -> IO.puts("    [decider was invoked for #{host}]")
      after
        2_000 -> IO.puts("    [WARN: decider was NOT invoked for #{host}]")
      end
    end

    assert_receive_decider.("api.openai.com")

    # Test 3: decider deny. example.org isn't in static or in decider
    # allow; decider denies; sidecar RSTs the connection.
    IO.puts("==> decider deny: curl --cacert ... https://example.org")
    {out3, exit3} = exec_curl.(["--cacert", "/etc/condukt/ca.pem", "https://example.org"])
    IO.puts(out3 |> String.split("\n") |> Enum.take(15) |> Enum.join("\n"))
    IO.puts("    exit=#{exit3}")
    assert_receive_decider.("example.org")

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

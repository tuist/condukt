defmodule Condukt.Sandbox.Net.K8s.ManifestsTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.Net.K8s.Manifests

  describe "secret/1" do
    test "builds a Secret with base64-encoded policy and cert" do
      manifest =
        Manifests.secret(%{
          name: "condukt-net-abc",
          namespace: "agents",
          session_id: "abc",
          policy_json: ~s({"allow_hosts":[]}),
          ca_cert_pem: "CERT",
          ca_key_pem: "KEY"
        })

      assert manifest["kind"] == "Secret"
      assert manifest["metadata"]["name"] == "condukt-net-abc"
      assert manifest["metadata"]["namespace"] == "agents"
      assert manifest["type"] == "Opaque"

      assert Base.decode64!(manifest["data"]["policy.json"]) == ~s({"allow_hosts":[]})
      assert Base.decode64!(manifest["data"]["ca.pem"]) == "CERT"
      assert Base.decode64!(manifest["data"]["ca-key.pem"]) == "KEY"
    end

    test "omits ca-key.pem when key is nil" do
      manifest =
        Manifests.secret(%{
          name: "x",
          namespace: "ns",
          session_id: "s",
          policy_json: "{}",
          ca_cert_pem: "C",
          ca_key_pem: nil
        })

      refute Map.has_key?(manifest["data"], "ca-key.pem")
    end
  end

  describe "network_policy/1" do
    test "scopes to the session pod label and restricts egress" do
      manifest =
        Manifests.network_policy(%{
          name: "condukt-net-abc",
          namespace: "agents",
          session_id: "abc"
        })

      assert manifest["kind"] == "NetworkPolicy"
      assert manifest["spec"]["policyTypes"] == ["Egress"]

      assert manifest["spec"]["podSelector"]["matchLabels"] ==
               %{Manifests.session_label() => "abc"}

      # DNS egress is allowed
      assert Enum.any?(manifest["spec"]["egress"], fn rule ->
               Enum.any?(rule["ports"] || [], fn p -> p["port"] == 53 end)
             end)

      # 80/443 egress allowed (to be used by the sidecar)
      assert Enum.any?(manifest["spec"]["egress"], fn rule ->
               Enum.any?(rule["ports"] || [], fn p -> p["port"] in [80, 443] end)
             end)
    end
  end

  describe "init_container/1" do
    test "runs netfilter-setup with NET_ADMIN capability" do
      manifest = Manifests.init_container()

      assert manifest["name"] == Manifests.init_container_name()
      assert manifest["args"] |> hd() == "netfilter-setup"
      assert manifest["securityContext"]["capabilities"]["add"] == ["NET_ADMIN", "NET_RAW"]
      assert manifest["securityContext"]["runAsUser"] == 0
    end
  end

  describe "sidecar_container/1" do
    test "runs proxy with required argv and sidecar uid" do
      manifest =
        Manifests.sidecar_container(%{
          session_id: "abc"
        })

      assert manifest["name"] == Manifests.sidecar_container_name()
      assert manifest["args"] |> hd() == "proxy"
      assert "--session-id" in manifest["args"]
      assert "abc" in manifest["args"]
      assert manifest["securityContext"]["runAsUser"] == Manifests.default_sidecar_uid()
      assert manifest["securityContext"]["runAsNonRoot"] == true
      assert manifest["securityContext"]["readOnlyRootFilesystem"] == true
      assert manifest["securityContext"]["capabilities"]["drop"] == ["ALL"]
    end

    test "exposes the proxy and control ports" do
      manifest = Manifests.sidecar_container(%{session_id: "abc"})
      ports = manifest["ports"] |> Enum.map(& &1["containerPort"])
      assert Manifests.default_proxy_port() in ports
      assert Manifests.default_control_port() in ports
    end
  end

  describe "secret_volume/1 and workspace_secret_volume_mount/0" do
    test "volume references the named Secret" do
      vol = Manifests.secret_volume("condukt-net-abc")
      assert vol["name"] == Manifests.secret_volume_name()
      assert vol["secret"]["secretName"] == "condukt-net-abc"
      assert vol["secret"]["defaultMode"] == 0o400
    end

    test "workspace mount is read-only at /etc/condukt" do
      mount = Manifests.workspace_secret_volume_mount()
      assert mount["mountPath"] == Manifests.ca_mount_path()
      assert mount["readOnly"] == true
    end
  end
end

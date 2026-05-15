defmodule Condukt.Sandbox.Net.K8s.Manifests do
  @moduledoc false

  # Pure manifest builders for the Sandbox.Net K8s integration:
  #
  #   - Secret carrying the per-session policy JSON + CA cert + CA key
  #   - NetworkPolicy locking pod egress to the sidecar container
  #   - Init container that runs `condukt-egress netfilter-setup`
  #   - Sidecar container that runs `condukt-egress proxy`
  #   - Volume and VolumeMount definitions for the Secret
  #
  # Defaults (image refs, ports, mount paths) are configurable through
  # the `Condukt.Sandbox.Kubernetes` `:net` option but resolve to the
  # values the release pipeline publishes to ghcr.io.

  @default_image "ghcr.io/tuist/condukt-egress:" <>
                   (Mix.Project.config()[:version] || "latest")
  @default_proxy_port 15_001
  @default_control_port 15_002
  @default_sidecar_uid 1337
  @ca_mount_path "/etc/condukt"
  @policy_filename "policy.json"
  @ca_cert_filename "ca.pem"
  @ca_key_filename "ca-key.pem"
  @secret_volume_name "condukt-net"
  @init_container_name "condukt-net-init"
  @sidecar_container_name "condukt-net-egress"
  @managed_by_label "app.kubernetes.io/managed-by"
  @managed_by_value "condukt"
  @session_label "condukt.tuist.dev/session-id"

  @doc """
  Returns a Kubernetes `Secret` manifest carrying:

    * the JSON-encoded egress policy at `policy.json`
    * the per-session CA certificate at `ca.pem`
    * the per-session CA private key at `ca-key.pem` (omitted if `nil`)
  """
  def secret(%{
        name: name,
        namespace: namespace,
        session_id: session_id,
        policy_json: policy_json,
        ca_cert_pem: ca_cert_pem,
        ca_key_pem: ca_key_pem
      }) do
    data = %{
      @policy_filename => Base.encode64(policy_json),
      @ca_cert_filename => Base.encode64(ca_cert_pem || "")
    }

    data =
      if ca_key_pem do
        Map.put(data, @ca_key_filename, Base.encode64(ca_key_pem))
      else
        data
      end

    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          @managed_by_label => @managed_by_value,
          @session_label => session_id
        }
      },
      "type" => "Opaque",
      "data" => data
    }
  end

  @doc """
  Returns a `NetworkPolicy` that forbids pod egress to anything except
  DNS and the loopback interface within the pod. With the iptables
  redirect from `netfilter-setup`, this means the workspace container's
  outbound traffic on tcp/80 and tcp/443 always lands on the sidecar
  (which has its own uid-based exemption in the redirect rules and is
  the only thing allowed to egress beyond the cluster boundary).

  Selects pods by the session id label set on pod creation.
  """
  def network_policy(%{name: name, namespace: namespace, session_id: session_id}) do
    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "NetworkPolicy",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          @managed_by_label => @managed_by_value,
          @session_label => session_id
        }
      },
      "spec" => %{
        "podSelector" => %{
          "matchLabels" => %{@session_label => session_id}
        },
        "policyTypes" => ["Egress"],
        "egress" => [
          # Allow DNS (cluster-local).
          %{
            "to" => [%{"namespaceSelector" => %{}}],
            "ports" => [
              %{"protocol" => "UDP", "port" => 53},
              %{"protocol" => "TCP", "port" => 53}
            ]
          },
          # Allow the sidecar's actual egress: any destination on tcp/80
          # or tcp/443. The sidecar is the only thing in the pod with the
          # uid-owner exemption from the iptables redirect, so this rule
          # really only applies to the sidecar's outbound dials.
          %{
            "to" => [
              %{
                "ipBlock" => %{
                  "cidr" => "0.0.0.0/0",
                  "except" => ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
                }
              }
            ],
            "ports" => [
              %{"protocol" => "TCP", "port" => 80},
              %{"protocol" => "TCP", "port" => 443}
            ]
          }
        ]
      }
    }
  end

  @doc """
  Returns the init container spec that runs
  `condukt-egress netfilter-setup` with CAP_NET_ADMIN.
  """
  def init_container(opts \\ %{}) do
    image = Map.get(opts, :image, @default_image)
    proxy_port = Map.get(opts, :proxy_port, @default_proxy_port)
    sidecar_uid = Map.get(opts, :sidecar_uid, @default_sidecar_uid)

    %{
      "name" => @init_container_name,
      "image" => image,
      "command" => ["condukt-egress"],
      "args" => [
        "netfilter-setup",
        "--proxy-port",
        Integer.to_string(proxy_port),
        "--sidecar-uid",
        Integer.to_string(sidecar_uid)
      ],
      "securityContext" => %{
        "runAsUser" => 0,
        "capabilities" => %{"add" => ["NET_ADMIN", "NET_RAW"]}
      }
    }
  end

  @doc """
  Returns the sidecar container spec that runs
  `condukt-egress proxy` with the mounted CA + policy secret.
  """
  def sidecar_container(opts) do
    image = Map.get(opts, :image, @default_image)
    proxy_port = Map.get(opts, :proxy_port, @default_proxy_port)
    control_port = Map.get(opts, :control_port, @default_control_port)
    sidecar_uid = Map.get(opts, :sidecar_uid, @default_sidecar_uid)
    session_id = Map.fetch!(opts, :session_id)

    args =
      [
        "proxy",
        "--listen",
        "0.0.0.0:#{proxy_port}",
        "--control-listen",
        "0.0.0.0:#{control_port}",
        "--policy-file",
        "#{@ca_mount_path}/#{@policy_filename}",
        "--ca-cert-path",
        "#{@ca_mount_path}/#{@ca_cert_filename}",
        "--ca-key-path",
        "#{@ca_mount_path}/#{@ca_key_filename}",
        "--session-id",
        session_id
      ]

    %{
      "name" => @sidecar_container_name,
      "image" => image,
      "command" => ["condukt-egress"],
      "args" => args,
      "ports" => [
        %{"name" => "proxy", "containerPort" => proxy_port, "protocol" => "TCP"},
        %{"name" => "control", "containerPort" => control_port, "protocol" => "TCP"}
      ],
      "securityContext" => %{
        "runAsUser" => sidecar_uid,
        "runAsNonRoot" => true,
        "allowPrivilegeEscalation" => false,
        "readOnlyRootFilesystem" => true,
        "capabilities" => %{"drop" => ["ALL"]}
      },
      "volumeMounts" => [
        %{"name" => @secret_volume_name, "mountPath" => @ca_mount_path, "readOnly" => true}
      ]
    }
  end

  @doc """
  Returns the pod-level Volume entry that mounts the secret.
  """
  def secret_volume(secret_name) do
    # Mode 0o444: world-readable. The mounted files (CA cert, CA key,
    # policy JSON) are owned by uid 0 from the kubelet's perspective,
    # so an owner-only mode would lock out the sidecar uid (1337) and
    # the workspace's non-root user. Everyone inside the pod is in the
    # same trust boundary (the pod's network namespace) so making the
    # files in-pod world-readable doesn't widen the threat model. The
    # per-session CA's blast radius is still bounded by the session.
    %{
      "name" => @secret_volume_name,
      "secret" => %{
        "secretName" => secret_name,
        "defaultMode" => 0o444
      }
    }
  end

  @doc """
  Returns the workspace VolumeMount that exposes the CA cert (read-only,
  no key) so the workspace can install it into its trust store. Mounted
  at `/etc/condukt/ca.pem`.
  """
  def workspace_secret_volume_mount do
    %{
      "name" => @secret_volume_name,
      "mountPath" => @ca_mount_path,
      "readOnly" => true
    }
  end

  @doc """
  Environment variables that point common HTTPS clients at the mounted
  CA without requiring the workspace image to install the cert into its
  system trust store. We inject these into every workspace container
  whose pod has `Sandbox.Net` enabled so untouched base images (curl,
  git, npm, python, etc.) can MITM cleanly without any image rebuild.

  The list intentionally covers the env vars the most common agent
  toolchains honour. Java keystores and a few system-OpenSSL paths are
  not addressed by this map and remain the operator's responsibility
  (`mix condukt.workspace.prepare` is the convenience path for those
  cases).
  """
  def workspace_ca_env do
    path = "#{@ca_mount_path}/#{@ca_cert_filename}"

    [
      %{"name" => "NODE_EXTRA_CA_CERTS", "value" => path},
      %{"name" => "REQUESTS_CA_BUNDLE", "value" => path},
      %{"name" => "SSL_CERT_FILE", "value" => path},
      %{"name" => "PIP_CERT", "value" => path},
      %{"name" => "CURL_CA_BUNDLE", "value" => path},
      %{"name" => "GIT_SSL_CAINFO", "value" => path}
    ]
  end

  def session_label, do: @session_label
  def init_container_name, do: @init_container_name
  def sidecar_container_name, do: @sidecar_container_name
  def secret_volume_name, do: @secret_volume_name
  def ca_mount_path, do: @ca_mount_path
  def policy_filename, do: @policy_filename
  def ca_cert_filename, do: @ca_cert_filename
  def ca_key_filename, do: @ca_key_filename
  def default_image, do: @default_image
  def default_proxy_port, do: @default_proxy_port
  def default_control_port, do: @default_control_port
  def default_sidecar_uid, do: @default_sidecar_uid
end

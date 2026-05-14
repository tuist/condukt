defmodule Condukt.Sandbox.Net.K8s do
  @moduledoc """
  Kubernetes-specific glue for the `Condukt.Sandbox.Net` egress layer.

  `Condukt.Sandbox.Kubernetes` calls into this module when an agent's
  sandbox spec sets `:net`. The module owns:

    * Generating a per-session ephemeral CA (`Condukt.Sandbox.Net.CA`)
    * Creating and deleting the K8s `Secret` that delivers the CA and
      the policy JSON to the sidecar
    * Creating and deleting the `NetworkPolicy` that restricts pod
      egress so the sidecar is the only thing that can reach the outside
      world
    * Augmenting the pod spec with the `condukt-egress` init container
      and sidecar plus the secret volume mount on the workspace container
    * Starting and stopping the BEAM-side control reader that decodes
      NDJSON events from the sidecar

  See `guides/net.md` for the full picture.
  """

  alias Condukt.Sandbox.Net.CA
  alias Condukt.Sandbox.Net.K8s.Manifests
  alias Condukt.Sandbox.Net.Policy

  @doc """
  Builds the per-session manifests and resolved options. Called by
  `Condukt.Sandbox.Kubernetes` before pod creation.

  Returns `{:ok, %{policy: Policy, secret: map, network_policy: map,
  init_container: map, sidecar_container: map, secret_volume: map,
  workspace_volume_mount: map, ca: CA.t(), names: %{...}}}`.
  """
  def prepare(%{session_id: session_id, namespace: namespace} = opts) do
    policy = Policy.new(Keyword.get(Map.get(opts, :net_opts, []), :policy, opts[:policy]))
    image = Keyword.get(Map.get(opts, :net_opts, []), :image, Manifests.default_image())
    proxy_port = Keyword.get(Map.get(opts, :net_opts, []), :proxy_port, Manifests.default_proxy_port())
    control_port = Keyword.get(Map.get(opts, :net_opts, []), :control_port, Manifests.default_control_port())
    sidecar_uid = Keyword.get(Map.get(opts, :net_opts, []), :sidecar_uid, Manifests.default_sidecar_uid())

    with {:ok, ca} <- CA.generate(common_name: session_id) do
      policy_json = encode_policy(policy)
      secret_name = "condukt-net-" <> sanitize(session_id)
      netpol_name = "condukt-net-" <> sanitize(session_id)

      secret =
        Manifests.secret(%{
          name: secret_name,
          namespace: namespace,
          session_id: session_id,
          policy_json: policy_json,
          ca_cert_pem: ca.cert_pem,
          ca_key_pem: ca.key_pem
        })

      network_policy =
        Manifests.network_policy(%{
          name: netpol_name,
          namespace: namespace,
          session_id: session_id
        })

      shared = %{
        image: image,
        proxy_port: proxy_port,
        control_port: control_port,
        sidecar_uid: sidecar_uid,
        session_id: session_id
      }

      init_container = Manifests.init_container(shared)
      sidecar_container = Manifests.sidecar_container(shared)
      secret_volume = Manifests.secret_volume(secret_name)
      workspace_volume_mount = Manifests.workspace_secret_volume_mount()

      {:ok,
       %{
         policy: policy,
         secret: secret,
         network_policy: network_policy,
         init_container: init_container,
         sidecar_container: sidecar_container,
         secret_volume: secret_volume,
         workspace_volume_mount: workspace_volume_mount,
         ca: ca,
         names: %{secret: secret_name, network_policy: netpol_name}
       }}
    end
  end

  @doc """
  Applies the prepared manifests to the cluster: creates the Secret and
  the NetworkPolicy. The pod spec gets the sidecar added by the caller;
  this function does not create the pod.
  """
  def apply(conn, %{secret: secret, network_policy: netpol}) do
    with {:ok, _} <- create_or_replace(conn, secret),
         {:ok, _} <- create_or_replace(conn, netpol) do
      :ok
    end
  end

  @doc """
  Removes the Secret and NetworkPolicy associated with a session. Called
  during `Condukt.Sandbox.Kubernetes` shutdown when `:delete_on_shutdown`
  is true. Errors are swallowed; teardown is best-effort.
  """
  def teardown(conn, namespace, %{secret: secret_name, network_policy: netpol_name}) do
    delete_resource(conn, "v1", "Secret", namespace, secret_name)
    delete_resource(conn, "networking.k8s.io/v1", "NetworkPolicy", namespace, netpol_name)
    :ok
  end

  defp encode_policy(%Policy{} = policy) do
    JSON.encode!(%{
      allow_hosts: policy.allow_hosts,
      deny_hosts: policy.deny_hosts,
      default: Atom.to_string(policy.default),
      max_body_capture: policy.max_body_capture,
      redact: Enum.map(policy.redact, &Regex.source/1),
      use_decider: policy.decide != nil,
      decide_timeout_ms: policy.decide_timeout
    })
  end

  defp create_or_replace(conn, manifest) do
    case K8s.Client.run(K8s.Client.put_conn(K8s.Client.create(manifest), conn)) do
      {:ok, resource} ->
        {:ok, resource}

      {:error, %{message: "already exists" <> _}} ->
        replace(conn, manifest)

      {:error, %K8s.Client.APIError{reason: "AlreadyExists"}} ->
        replace(conn, manifest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace(conn, manifest) do
    op = K8s.Client.update(manifest) |> K8s.Client.put_conn(conn)

    case K8s.Client.run(op) do
      {:ok, resource} -> {:ok, resource}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_resource(conn, api_version, kind, namespace, name) do
    op =
      K8s.Client.delete(api_version, kind, namespace: namespace, name: name)
      |> K8s.Client.put_conn(conn)

    K8s.Client.run(op)
  end

  defp sanitize(string) do
    string
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.slice(0, 50)
  end
end

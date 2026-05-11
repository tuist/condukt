defmodule Condukt.Sandbox.Kubernetes.PodSpec do
  @moduledoc false

  # Builds the Pod manifest map handed to `K8s.Client.create/1`.
  #
  # Choices baked in:
  #
  # - `restartPolicy: Always` so K8s restarts the keepalive container on
  #   crash. The workspace `emptyDir` volume survives container restarts.
  # - One `emptyDir` volume mounted at the session cwd so repo clones and
  #   in-progress edits persist across container restarts within the same pod.
  # - `command: ["sleep", "infinity"]` keepalive so the pod never exits on its
  #   own. All real work happens via `kubectl exec`-style streaming.
  # - `activeDeadlineSeconds` as a K8s-side hard ceiling for abandoned pods.

  @workspace_volume "condukt-workspace"
  @container_name "agent"

  def build(%{
        pod_name: pod_name,
        namespace: namespace,
        image: image,
        cwd: cwd,
        labels: labels,
        annotations: annotations,
        env: env,
        resources: resources,
        service_account: service_account,
        active_deadline_seconds: deadline
      }) do
    container = %{
      "name" => @container_name,
      "image" => image,
      "command" => ["sleep", "infinity"],
      "workingDir" => cwd,
      "volumeMounts" => [
        %{"name" => @workspace_volume, "mountPath" => cwd}
      ]
    }

    spec = %{
      "restartPolicy" => "Always",
      "containers" => [
        container
        |> maybe_put_env(env)
        |> maybe_put_resources(resources)
      ],
      "volumes" => [
        %{"name" => @workspace_volume, "emptyDir" => %{}}
      ]
    }

    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => pod_name,
        "namespace" => namespace,
        "labels" => labels,
        "annotations" => annotations
      },
      "spec" =>
        spec
        |> maybe_put_active_deadline(deadline)
        |> maybe_put_service_account(service_account)
    }
  end

  def container_name, do: @container_name

  defp maybe_put_env(container, env) when map_size(env) == 0, do: container

  defp maybe_put_env(container, env) do
    Map.put(container, "env", Enum.map(env, fn {k, v} -> %{"name" => k, "value" => v} end))
  end

  defp maybe_put_resources(container, resources) when map_size(resources) == 0, do: container
  defp maybe_put_resources(container, resources), do: Map.put(container, "resources", resources)

  defp maybe_put_active_deadline(spec, nil), do: spec
  defp maybe_put_active_deadline(spec, seconds), do: Map.put(spec, "activeDeadlineSeconds", seconds)

  defp maybe_put_service_account(spec, nil), do: spec
  defp maybe_put_service_account(spec, name), do: Map.put(spec, "serviceAccountName", name)
end

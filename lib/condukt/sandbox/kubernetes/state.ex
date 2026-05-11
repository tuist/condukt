defmodule Condukt.Sandbox.Kubernetes.State do
  @moduledoc false

  defstruct [
    :conn,
    :namespace,
    :pod_name,
    :container,
    :base_cwd,
    :id,
    :delete_on_shutdown
  ]
end

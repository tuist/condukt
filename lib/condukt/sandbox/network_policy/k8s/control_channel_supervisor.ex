defmodule Condukt.Sandbox.NetworkPolicy.K8s.ControlChannelSupervisor do
  @moduledoc false

  # Application-level registry of per-session network-policy control
  # channels. One `...K8s.ControlChannel` subtree is started here per
  # Kubernetes sandbox whose policy has a `:decide` rule.
  #
  # Children are `:temporary`: a per-session subtree is never
  # resurrected by this supervisor. If it dies (the owning session is
  # gone, or its bounded restart intensity was exceeded) it stays gone;
  # a fresh session starts a fresh one. That keeps every session's
  # failure domain isolated from every other session's.

  use DynamicSupervisor

  alias Condukt.Sandbox.NetworkPolicy.K8s.ControlChannel

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a per-session control-channel subtree. `bridge_opts` are the
  options forwarded to `...K8s.ControlBridge`. Returns
  `{:ok, channel_pid}` where `channel_pid` is the per-session
  `ControlChannel` supervisor (store it; pass it to `stop_session/2`).
  """
  def start_session(bridge_opts, supervisor \\ __MODULE__) do
    DynamicSupervisor.start_child(supervisor, {ControlChannel, bridge_opts})
  end

  @doc """
  Tears down a per-session control-channel subtree. Idempotent: a
  channel that already collapsed on its own (its owner went away and
  the subtree auto-shut-down) is reported as `:ok`, not an error, so
  explicit teardown after an implicit one is a clean no-op.
  """
  def stop_session(pid, supervisor \\ __MODULE__)

  def stop_session(pid, supervisor) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  def stop_session(_pid, _supervisor), do: :ok
end

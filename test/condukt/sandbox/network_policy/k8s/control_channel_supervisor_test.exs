defmodule Condukt.Sandbox.NetworkPolicy.K8s.ControlChannelSupervisorTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.NetworkPolicy
  alias Condukt.Sandbox.NetworkPolicy.K8s.ControlChannelSupervisor

  setup do
    # A private DynamicSupervisor instance so the suite stays async and
    # isolated from the application-level singleton.
    sup = start_supervised!({ControlChannelSupervisor, name: :"ccs_#{System.unique_integer([:positive])}"})
    %{sup: sup}
  end

  defp opts(connector) do
    [
      conn: :stub,
      namespace: "ns",
      pod_name: "pod",
      session_id: "s1",
      policy: %NetworkPolicy{},
      owner_pid: self(),
      connector: connector
    ]
  end

  # A real gen_server (Agent) stand-in for PortForward: ControlBridge
  # stops it via GenServer.stop on teardown.
  defp ok_connector do
    fn _owner ->
      {:ok, _pid} = Agent.start(fn -> :ok end)
    end
  end

  test "start_session brings up an isolated per-session subtree", %{sup: sup} do
    assert {:ok, channel} = ControlChannelSupervisor.start_session(opts(ok_connector()), sup)
    assert is_pid(channel)
    assert Process.alive?(channel)
    assert [{:undefined, ^channel, :supervisor, _}] = DynamicSupervisor.which_children(sup)
  end

  test "stop_session tears the subtree down and is idempotent", %{sup: sup} do
    {:ok, channel} = ControlChannelSupervisor.start_session(opts(ok_connector()), sup)
    ref = Process.monitor(channel)

    assert :ok = ControlChannelSupervisor.stop_session(channel, sup)
    assert_receive {:DOWN, ^ref, :process, ^channel, _}, 1_000

    # Already gone: explicit teardown after the subtree collapsed (or a
    # double stop) is a clean :ok, never {:error, :not_found}.
    assert :ok = ControlChannelSupervisor.stop_session(channel, sup)
    assert :ok = ControlChannelSupervisor.stop_session(nil, sup)
  end

  test "sessions are independent: one going down leaves the other up", %{sup: sup} do
    {:ok, a} = ControlChannelSupervisor.start_session(opts(ok_connector()), sup)
    {:ok, b} = ControlChannelSupervisor.start_session(opts(ok_connector()), sup)

    ref = Process.monitor(a)
    ControlChannelSupervisor.stop_session(a, sup)
    assert_receive {:DOWN, ^ref, :process, ^a, _}, 1_000

    refute Process.alive?(a)
    assert Process.alive?(b)
  end

  test "start_session surfaces a failure when the bridge cannot connect", %{sup: sup} do
    failing = fn _owner -> {:error, :unreachable} end
    assert {:error, _reason} = ControlChannelSupervisor.start_session(opts(failing), sup)
  end
end

defmodule Condukt.Sandbox.NetworkPolicy.K8s.ControlChannelTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.NetworkPolicy
  alias Condukt.Sandbox.NetworkPolicy.K8s.ControlBridge
  alias Condukt.Sandbox.NetworkPolicy.K8s.ControlChannel

  # A stand-in for the PortForward worker so ControlBridge init
  # succeeds without a cluster (its connector is injectable). It is a
  # real gen_server (Agent) because ControlBridge.terminate stops it
  # via PortForward.close -> GenServer.stop.
  defp fake_pf do
    {:ok, pid} = Agent.start(fn -> :ok end)
    pid
  end

  defp opts(owner) do
    [
      conn: :stub,
      namespace: "ns",
      pod_name: "pod",
      session_id: "s1",
      policy: %NetworkPolicy{},
      owner_pid: owner,
      connector: fn _owner -> {:ok, fake_pf()} end
    ]
  end

  defp bridge_pid(channel) do
    case Supervisor.which_children(channel) do
      [{ControlBridge, pid, _type, _modules}] when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp wait_for(fun, tries \\ 50) do
    cond do
      tries == 0 ->
        nil

      result = fun.() ->
        result

      true ->
        Process.sleep(20)
        wait_for(fun, tries - 1)
    end
  end

  test "child_spec is a temporary supervisor" do
    spec = ControlChannel.child_spec([])
    assert spec.restart == :temporary
    assert spec.type == :supervisor
  end

  test "supervises a single ControlBridge" do
    channel = start_supervised!({ControlChannel, opts(self())})
    assert is_pid(bridge_pid(channel))
  end

  test "restarts the bridge on an abnormal exit (transient)" do
    channel = start_supervised!({ControlChannel, opts(self())})
    b1 = bridge_pid(channel)

    Process.exit(b1, :kill)

    b2 =
      wait_for(fn ->
        case bridge_pid(channel) do
          p when is_pid(p) and p != b1 -> p
          _ -> nil
        end
      end)

    assert is_pid(b2)
    assert b2 != b1
    assert Process.alive?(channel)
  end

  test "auto-shuts-down when the owner dies (significant + transient + auto_shutdown)" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    channel = start_supervised!({ControlChannel, opts(owner)})
    ref = Process.monitor(channel)

    # Owner gone -> bridge stops :normal -> not restarted (transient) ->
    # significant child not restarted -> the whole subtree collapses.
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^channel, _reason}, 2_000
  end
end

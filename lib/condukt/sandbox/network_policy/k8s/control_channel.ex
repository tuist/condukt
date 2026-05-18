defmodule Condukt.Sandbox.NetworkPolicy.K8s.ControlChannel do
  @moduledoc false

  # Per-session supervisor for one network-policy control channel.
  #
  # It supervises a single `...K8s.ControlBridge`, with rules chosen so
  # the subtree's lifetime tracks the gated session:
  #
  #   * `restart: :transient` - the bridge is restarted only on an
  #     abnormal exit (a bug, or a connect loop that exhausted its
  #     reconnect budget). A clean `:normal` exit is not restarted.
  #   * `significant: true` + `auto_shutdown: :any_significant` - when
  #     the bridge exits `:normal` (the owning session went away, so
  #     there is nothing left to gate) and is therefore not restarted,
  #     this supervisor shuts itself down too. The whole per-session
  #     subtree collapses with no orphans.
  #   * bounded `max_restarts`/`max_seconds` - a permanently
  #     unreachable apiserver makes this supervisor give up rather than
  #     hot-loop forever. The session keeps running; `:decide` requests
  #     then fail closed via the sidecar's decide timeout.
  #
  # Started as a `:temporary` child of `...K8s.ControlChannelSupervisor`
  # so the parent never resurrects a per-session subtree on its own.

  use Supervisor

  alias Condukt.Sandbox.NetworkPolicy.K8s.ControlBridge

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    children = [
      %{
        id: ControlBridge,
        start: {ControlBridge, :start_link, [opts]},
        type: :worker,
        restart: :transient,
        significant: true,
        shutdown: 5_000
      }
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      auto_shutdown: :any_significant,
      max_restarts: 5,
      max_seconds: 30
    )
  end
end

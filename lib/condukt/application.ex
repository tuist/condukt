defmodule Condukt.Application do
  @moduledoc false

  use Application

  alias Condukt.Engine

  # The control channel for a `:decide` network policy is a per-session
  # `...K8s.ControlBridge` started as a `:transient` child of this
  # DynamicSupervisor (the standard "dynamic children under the app
  # root" pattern). Bounded restart intensity so a genuinely buggy
  # bridge can't hot-loop the whole pool; a bridge that merely can't
  # reach its control port gives up `:normal` and is dropped, not
  # restarted, so it never counts against the intensity.
  @control_channel_supervisor Condukt.Sandbox.NetworkPolicy.K8s.ControlChannelSupervisor

  def control_channel_supervisor, do: @control_channel_supervisor

  @impl true
  def start(_type, _args) do
    register_providers()

    # Comes up before the engine Task, which can create sessions.
    children =
      [
        {DynamicSupervisor,
         name: @control_channel_supervisor, strategy: :one_for_one, max_restarts: 10, max_seconds: 60}
      ] ++
        if engine_release?() do
          [{Task, fn -> run_engine() end}]
        else
          []
        end

    Supervisor.start_link(children, strategy: :one_for_one, name: Condukt.Supervisor)
  end

  defp register_providers do
    ReqLLM.Providers.register(Condukt.Providers.Ollama)
  end

  defp engine_release? do
    burrito_util = Module.concat([Burrito, Util])

    if Code.ensure_loaded?(burrito_util) and function_exported?(burrito_util, :running_standalone?, 0) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(burrito_util, :running_standalone?, [])
    else
      false
    end
  end

  defp run_engine do
    Engine.CLI.main(engine_args())
    |> System.halt()
  end

  defp engine_args do
    burrito_args = Module.concat([Burrito, Util, Args])

    if Code.ensure_loaded?(burrito_args) and function_exported?(burrito_args, :argv, 0) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(burrito_args, :argv, [])
    else
      System.argv()
    end
  end
end

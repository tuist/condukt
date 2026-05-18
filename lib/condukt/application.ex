defmodule Condukt.Application do
  @moduledoc false

  use Application

  alias Condukt.Engine
  alias Condukt.Sandbox.NetworkPolicy.K8s.ControlChannelSupervisor

  @impl true
  def start(_type, _args) do
    register_providers()

    # The control-channel registry is always supervised: a K8s sandbox
    # with a `:decide` policy starts its per-session subtree under it.
    # It comes up before the engine Task, which can create sessions.
    children =
      [ControlChannelSupervisor] ++
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

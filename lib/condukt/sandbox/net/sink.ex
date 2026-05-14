defmodule Condukt.Sandbox.Net.Sink do
  @moduledoc """
  Behaviour for delivering `Condukt.Sandbox.Net.Event` records.

  A sink is the BEAM-side destination for events emitted by the egress
  sidecar. The default sink (`Condukt.Sandbox.Net.Sink.Log`) emits telemetry
  events and a `Logger.info/1` line per request. Applications wiring net
  events into their own UI, audit store, or queue typically implement a
  custom sink or use `Condukt.Sandbox.Net.Sink.Process` to forward events
  to an existing process.

  Implementations are stateless from the runtime's perspective: each
  `deliver/2` call receives the configured opts. If you need state, hold it
  in a process the sink forwards into.
  """

  alias Condukt.Sandbox.Net.Event

  @callback deliver(event :: Event.t(), opts :: keyword()) :: :ok

  @doc """
  Delivers an event to a resolved sink reference.

  Accepted sink shapes:

    * `pid()` or registered atom name: delivered as `{:condukt_sandbox_net_event, event}`
    * `module` (atom): calls `module.deliver(event, [])`
    * `{module, opts}`: calls `module.deliver(event, opts)`
    * `nil`: drops the event silently
  """
  def deliver(nil, %Event{}), do: :ok

  def deliver(pid, %Event{} = event) when is_pid(pid) do
    send(pid, {:condukt_sandbox_net_event, event})
    :ok
  end

  def deliver(name, %Event{} = event) when is_atom(name) do
    cond do
      Process.whereis(name) ->
        send(name, {:condukt_sandbox_net_event, event})
        :ok

      Code.ensure_loaded?(name) and function_exported?(name, :deliver, 2) ->
        name.deliver(event, [])

      true ->
        :ok
    end
  end

  def deliver({module, opts}, %Event{} = event) when is_atom(module) and is_list(opts) do
    module.deliver(event, opts)
  end
end

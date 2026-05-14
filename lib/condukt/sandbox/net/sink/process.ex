defmodule Condukt.Sandbox.Net.Sink.Process do
  @moduledoc """
  `Condukt.Sandbox.Net.Sink` that forwards events to a process.

  Useful for tests and for sessions that want to consume net events
  alongside their existing event stream. The target is configured via the
  `:to` option, which accepts a `pid()` or a registered atom name.

  ## Example

      policy = %Condukt.Sandbox.Net.Policy{
        allow_hosts: ["*.github.com"],
        sink: {Condukt.Sandbox.Net.Sink.Process, to: self()}
      }

  Events arrive as `{:condukt_sandbox_net_event, event}` messages.
  """

  @behaviour Condukt.Sandbox.Net.Sink

  alias Condukt.Sandbox.Net.Sink

  @impl true
  def deliver(event, opts) do
    case Keyword.fetch(opts, :to) do
      {:ok, target} -> Sink.deliver(target, event)
      :error -> :ok
    end
  end
end

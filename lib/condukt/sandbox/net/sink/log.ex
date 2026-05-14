defmodule Condukt.Sandbox.Net.Sink.Log do
  @moduledoc """
  Default `Condukt.Sandbox.Net.Sink` that logs each event and emits telemetry.

  Telemetry event:

      [:condukt, :sandbox, :net, kind]

  with measurements `%{bytes_in: ..., bytes_out: ...}` and metadata
  `%{request: Condukt.Sandbox.Net.Request.t(), reason: atom() | nil}`.
  """

  @behaviour Condukt.Sandbox.Net.Sink

  alias Condukt.Sandbox.Net.Event

  require Logger

  @impl true
  def deliver(%Event{kind: kind, request: request, reason: reason}, _opts) do
    :telemetry.execute(
      [:condukt, :sandbox, :net, kind],
      %{bytes_in: request.bytes_in, bytes_out: request.bytes_out},
      %{request: request, reason: reason}
    )

    Logger.info(fn ->
      base = "[sandbox.net] #{kind} #{request.scheme}://#{request.host}:#{request.port}"

      with_method =
        case request.method do
          nil -> base
          method -> "#{base} #{method} #{request.path || "/"}"
        end

      case reason do
        nil -> with_method
        reason -> "#{with_method} (#{reason})"
      end
    end)

    :ok
  end
end

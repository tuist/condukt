defmodule Condukt.Session.Compaction do
  @moduledoc false

  alias Condukt.Compactor
  alias Condukt.Telemetry

  require Logger

  def apply(nil, messages, _metadata), do: messages

  def apply(compactor, messages, metadata) do
    started = System.monotonic_time()
    before_bytes = :erlang.external_size(messages)
    Telemetry.emit([:compact, :start], %{system_time: System.system_time()}, metadata)

    {compacted, status} =
      case Compactor.compact(compactor, messages) do
        {:ok, compacted} ->
          {compacted, :ok}

        {:error, _reason} ->
          Logger.warning("compaction failed; preserving original history")
          {messages, :error}
      end

    Telemetry.emit(
      [:compact, :stop],
      %{
        duration: System.monotonic_time() - started,
        before: length(messages),
        after: length(compacted),
        before_bytes: before_bytes,
        after_bytes: :erlang.external_size(compacted)
      },
      Map.merge(metadata, %{status: status, changed: compacted != messages})
    )

    compacted
  end
end

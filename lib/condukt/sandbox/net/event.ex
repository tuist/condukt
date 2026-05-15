defmodule Condukt.Sandbox.Net.Event do
  @moduledoc """
  An event the egress runtime emits as telemetry per request lifecycle.

  The egress sidecar emits an event when a request starts (`:request_opened`),
  when its outcome is known (`:request_closed`), and when policy decides on the
  request (`:request_allowed` or `:request_denied`).

  Most callers only care about `:request_closed`. The lifecycle separation
  exists so suspension-point gating (held between `:request_opened` and the
  decision) can surface live in-flight requests to a UI or human reviewer.
  """

  alias Condukt.Sandbox.Net.Request

  defstruct [:kind, :request, :reason, at: nil]

  @doc """
  Builds an event from a decoded `Condukt.Sandbox.Net.Request` plus kind.
  """
  def new(kind, %Request{} = request, opts \\ []) do
    %__MODULE__{
      kind: kind,
      request: request,
      reason: Keyword.get(opts, :reason),
      at: Keyword.get(opts, :at, DateTime.utc_now())
    }
  end
end

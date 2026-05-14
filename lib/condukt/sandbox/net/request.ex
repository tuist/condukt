defmodule Condukt.Sandbox.Net.Request do
  @moduledoc """
  A single outbound network request observed by the sandbox egress layer.

  Requests are emitted by `Condukt.Sandbox.Net`-capable sandboxes (today,
  `Condukt.Sandbox.Kubernetes` via the `condukt-egress` sidecar) and delivered
  to the configured `Condukt.Sandbox.Net.Sink`. They flow into the session
  event stream alongside tool calls.

  The `:tier` field records how much of the request the capture mechanism saw:

    * `:sni` — only the TLS Server Name Indication and connection metadata.
      Always available on K8s when the egress sidecar is in place, regardless
      of the workspace image.
    * `:body` — full method, path, headers, and body. Only available when the
      workspace image trusts the per-session CA (Tier 2; cooperative image).
    * `:cleartext` — HTTP without TLS. Rare in practice but possible.

  Bodies and headers may be partially redacted by the sidecar according to the
  `Condukt.Sandbox.Net.Policy` redaction patterns.
  """

  defstruct id: nil,
            session_id: nil,
            tier: :sni,
            host: nil,
            port: 443,
            remote_addr: nil,
            method: nil,
            path: nil,
            scheme: "https",
            request_headers: nil,
            request_body_sha256: nil,
            request_body_preview: nil,
            request_body_truncated: false,
            response_status: nil,
            response_headers: nil,
            response_body_sha256: nil,
            response_body_preview: nil,
            response_body_truncated: false,
            bytes_in: 0,
            bytes_out: 0,
            started_at: nil,
            finished_at: nil,
            initiator: nil

  @doc """
  Decodes a request from the NDJSON wire format emitted by `condukt-egress`.

  Unknown keys are ignored so the protocol can evolve forward-compatibly.
  Required fields: `id`, `host`, `port`, `tier`, `started_at`.
  """
  def from_json(%{"id" => id, "host" => host, "port" => port, "tier" => tier, "started_at" => started_at} = json) do
    with {:ok, started_at} <- parse_datetime(started_at),
         {:ok, finished_at} <- parse_optional_datetime(Map.get(json, "finished_at")),
         {:ok, tier} <- parse_tier(tier) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: Map.get(json, "session_id"),
         tier: tier,
         host: host,
         port: port,
         remote_addr: Map.get(json, "remote_addr"),
         method: Map.get(json, "method"),
         path: Map.get(json, "path"),
         scheme: Map.get(json, "scheme", "https"),
         request_headers: Map.get(json, "request_headers"),
         request_body_sha256: Map.get(json, "request_body_sha256"),
         request_body_preview: Map.get(json, "request_body_preview"),
         request_body_truncated: Map.get(json, "request_body_truncated", false),
         response_status: Map.get(json, "response_status"),
         response_headers: Map.get(json, "response_headers"),
         response_body_sha256: Map.get(json, "response_body_sha256"),
         response_body_preview: Map.get(json, "response_body_preview"),
         response_body_truncated: Map.get(json, "response_body_truncated", false),
         bytes_in: Map.get(json, "bytes_in", 0),
         bytes_out: Map.get(json, "bytes_out", 0),
         started_at: started_at,
         finished_at: finished_at,
         initiator: Map.get(json, "initiator")
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_request, other}}

  defp parse_tier("sni"), do: {:ok, :sni}
  defp parse_tier("body"), do: {:ok, :body}
  defp parse_tier("cleartext"), do: {:ok, :cleartext}
  defp parse_tier(other), do: {:error, {:invalid_tier, other}}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, {:invalid_datetime, reason}}
    end
  end

  defp parse_datetime(other), do: {:error, {:invalid_datetime, other}}

  defp parse_optional_datetime(nil), do: {:ok, nil}
  defp parse_optional_datetime(value), do: parse_datetime(value)
end

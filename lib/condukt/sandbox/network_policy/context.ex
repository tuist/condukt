defmodule Condukt.Sandbox.NetworkPolicy.Context do
  @moduledoc """
  Snapshot of session state handed to a `Condukt.Sandbox.NetworkPolicy`
  `:decide` callback per outbound request.

  The runtime assembles this struct when an outbound connection does not
  match the static `allow_hosts` / `deny_hosts` fast-path and the policy
  has a decider configured. It is the only context the decider sees: a
  decider cannot reach back into the session itself.

  Fields:

    * `:session_id` — the gated session's id.
    * `:recent_messages` — the last `Policy.context_messages` messages
      from the session, oldest first. Redaction (`Condukt.Redactor`)
      is applied before they leave the session, so the decider sees
      whatever the rest of the system would.
    * `:request` — the `Condukt.Sandbox.NetworkPolicy.Request` the agent is about
      to make. Method, path, and request headers are populated where
      the sidecar derived them pre-decision. Body is not in the
      context (kept out to bound the decider's input cost).
    * `:metadata` — caller-supplied per-session metadata, set via
      `Policy.context_metadata`. Useful for user identity, tenant,
      session purpose, etc.
  """

  defstruct session_id: nil,
            recent_messages: [],
            request: nil,
            metadata: %{}
end

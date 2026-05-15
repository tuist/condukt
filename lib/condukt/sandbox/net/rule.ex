defmodule Condukt.Sandbox.Net.Rule do
  @moduledoc """
  Behaviour for `Condukt.Sandbox.Net.Policy` rules.

  A policy is an ordered list of rules. For each outbound request the
  runtime walks the list in order; the first rule that returns
  `:allow` or `{:deny, reason}` wins. A rule that returns `:continue`
  defers to whatever comes next. If every rule passes, the policy's
  `:default` action applies.

  The shape is intentionally close to a `Plug` pipeline. Order is
  semantically meaningful, and a rule can short-circuit the pipeline
  by returning a decision rather than `:continue`.

  Built-in rules:

    * `Condukt.Sandbox.Net.Rule.AllowHosts` — matches against host glob
      patterns, returns `:allow` on a hit and `:continue` otherwise.
    * `Condukt.Sandbox.Net.Rule.DenyHosts` — symmetrical deny match.
    * `Condukt.Sandbox.Net.Rule.Decide` — defers the decision to a
      decider callable (function, MFA tuple, or behaviour module).

  Callers can write their own rule modules by implementing this
  behaviour. The runtime instantiates rules either as a module (with
  empty opts) or as a `{module, opts}` tuple. The opts term is whatever
  the rule module documents.

  Implementations receive the `Condukt.Sandbox.Net.Context` (which
  carries the session id, recent messages, request, and per-session
  metadata), the `Condukt.Sandbox.Net.Request` being evaluated, and
  the opts the rule was configured with.
  """

  @callback evaluate(
              context :: Condukt.Sandbox.Net.Context.t(),
              request :: Condukt.Sandbox.Net.Request.t(),
              opts :: keyword()
            ) :: :allow | {:deny, term()} | :continue
end

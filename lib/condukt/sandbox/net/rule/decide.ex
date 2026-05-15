defmodule Condukt.Sandbox.Net.Rule.Decide do
  @moduledoc """
  `Condukt.Sandbox.Net.Rule` that defers to a decider callable.

  This is the rule that turns a policy from a static list of hosts into
  a runtime evaluator backed by code or by another agent. The runtime
  invokes the decider with the same context and request the rule
  received, and propagates the decider's answer (`:allow` or
  `{:deny, reason}`) verbatim. Deciders never return `:continue` — if
  you want a tiered policy, put narrower rules ahead of this one in the
  pipeline.

  Configured as one of:

    * a 2-arity function (`(context, request) -> :allow | {:deny, reason}`),
      under the `:fun` opt;
    * an `{module, function}` tuple, under the `:mf` opt;
    * a behaviour-backed module and opts, under the `:module` and
      `:opts` keys.

  The behaviour module form is the one you reach for when you want a
  Condukt agent to make the call: see
  `Condukt.Sandbox.Net.AgentDecider`.

  Timeouts, error handling, and per-session decision caching apply per
  `Condukt.Sandbox.Net.Decider` and are configured on the parent
  `Condukt.Sandbox.Net.Policy`, not on this rule.
  """

  @behaviour Condukt.Sandbox.Net.Rule

  alias Condukt.Sandbox.Net.Decider

  @impl true
  def evaluate(context, request, opts) do
    decider = resolve(opts)
    Decider.invoke(decider, context, request, Keyword.get(opts, :decider_opts, []))
  end

  defp resolve(opts) do
    cond do
      fun = Keyword.get(opts, :fun) -> fun
      mf = Keyword.get(opts, :mf) -> mf
      mod = Keyword.get(opts, :module) -> {mod, Keyword.get(opts, :opts, [])}
      true -> raise ArgumentError, "Rule.Decide requires :fun, :mf, or :module"
    end
  end
end

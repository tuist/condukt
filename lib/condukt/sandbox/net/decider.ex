defmodule Condukt.Sandbox.Net.Decider do
  @moduledoc """
  Behaviour and runtime for `Condukt.Sandbox.Net.Policy` deciders.

  A decider takes a `Condukt.Sandbox.Net.Context` and a
  `Condukt.Sandbox.Net.Request` and returns `:allow` or
  `{:deny, reason}`. Three shapes are accepted on a `Policy`'s
  `:decide` field:

    * A 2-arity function: `fn ctx, req -> :allow end`
    * A `{module, function}` tuple: `module.function(ctx, req)`
    * A `{module, opts}` tuple: `module.decide(ctx, req, opts)` —
      the module is expected to implement this behaviour. Use
      `Condukt.Sandbox.Net.AgentDecider` to wrap a Condukt agent
      module as a decider.

  ## Runtime semantics

  Decider invocations run in a separate process with a configurable
  timeout (`Policy.decide_timeout`, default 5000ms). On timeout, an
  exception, or any non-`:allow | {:deny, reason}` return value, the
  request is denied with `{:deny, :decider_error}` or
  `{:deny, :decider_timeout}` and an entry surfaces in telemetry.

  Decisions are cached per-session per-host when
  `Policy.decision_cache` is true (default). The cache is in-process
  and dies with the session. Pass `false` to invoke the decider on
  every connection (useful when context outside the host is part of
  the decision).
  """

  alias Condukt.Sandbox.Net.Context
  alias Condukt.Sandbox.Net.Policy
  alias Condukt.Sandbox.Net.Request

  @callback decide(context :: Context.t(), request :: Request.t(), opts :: keyword()) ::
              :allow | {:deny, term()}

  @doc """
  Invokes the decider configured on the policy. Applies timeout, error
  handling, and the per-session decision cache.

  The `cache` parameter is an opaque map keyed by host string; pass
  `%{}` if not caching. Returns `{decision, updated_cache}`.
  """
  def decide(%Policy{decide: nil} = policy, _context, _request, cache) do
    {default_decision(policy), cache}
  end

  def decide(%Policy{} = policy, %Context{} = context, %Request{} = request, cache) do
    if policy.decision_cache do
      case Map.fetch(cache, request.host) do
        {:ok, cached} -> {cached, cache}
        :error -> invoke_and_cache(policy, context, request, cache)
      end
    else
      {invoke(policy, context, request), cache}
    end
  end

  defp invoke_and_cache(policy, context, request, cache) do
    decision = invoke(policy, context, request)
    {decision, Map.put(cache, request.host, decision)}
  end

  defp invoke(policy, context, request) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = run_decider(policy.decide, context, request)
        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        validate_decision(result, policy)

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        emit_failure(:decider_error, policy, request)
        default_decision(policy)
    after
      policy.decide_timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          0 -> :ok
        end

        emit_failure(:decider_timeout, policy, request)
        default_decision(policy)
    end
  end

  defp run_decider(decider, context, request) when is_function(decider, 2) do
    decider.(context, request)
  end

  defp run_decider({mod, fun}, context, request) when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [context, request])
  end

  defp run_decider({mod, opts}, context, request) when is_atom(mod) and is_list(opts) do
    mod.decide(context, request, opts)
  end

  defp run_decider(mod, context, request) when is_atom(mod) do
    mod.decide(context, request, [])
  end

  defp validate_decision(:allow, _policy), do: :allow
  defp validate_decision({:deny, _reason} = decision, _policy), do: decision

  defp validate_decision(_other, policy) do
    emit_failure(:decider_bad_return, policy, nil)
    default_decision(policy)
  end

  defp default_decision(%Policy{default: :allow}), do: :allow
  defp default_decision(%Policy{default: :deny}), do: {:deny, :default_deny}

  defp emit_failure(reason, _policy, _request) do
    :telemetry.execute(
      [:condukt, :sandbox, :net, :decider_failure],
      %{count: 1},
      %{reason: reason}
    )
  end
end

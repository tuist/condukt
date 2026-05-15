defmodule Condukt.Sandbox.NetworkPolicy.Decider do
  @moduledoc """
  Behaviour and runtime for the `:decide` rule on a
  `Condukt.Sandbox.NetworkPolicy`.

  A decider receives a `Condukt.Sandbox.NetworkPolicy.Context` and a
  `Condukt.Sandbox.NetworkPolicy.Request` and returns `:allow` or
  `{:deny, reason}`. Four shapes are accepted as the rule's value:

    * A 2-arity function: `fn ctx, req -> :allow end`
    * `{module, function}` (both atoms): `module.function(ctx, req)`
    * A module atom alone: `module.decide(ctx, req, [])`
    * `{module, opts}` (a keyword list): `module.decide(ctx, req, opts)`

  Use `Condukt.Sandbox.NetworkPolicy.AgentDecider` to wrap a Condukt
  agent module as a decider.

  ## Runtime semantics

  Decider invocations run in a separate process with a configurable
  timeout (`Policy.decide_timeout`, default 5000ms). On timeout, an
  exception, or any non-`:allow | {:deny, reason}` return value, the
  request is denied with a structured reason and an entry surfaces in
  telemetry.

  Decisions are cached per-session per-host when
  `Policy.decision_cache` is true (default). The cache is in-process
  and dies with the session.
  """

  alias Condukt.Sandbox.NetworkPolicy
  alias Condukt.Sandbox.NetworkPolicy.Context
  alias Condukt.Sandbox.NetworkPolicy.Request

  @callback decide(context :: Context.t(), request :: Request.t(), opts :: keyword()) ::
              :allow | {:deny, term()}

  @doc """
  Invokes a decider once, in an isolated process bounded by `timeout`
  milliseconds. Used directly by `Condukt.Sandbox.NetworkPolicy`'s
  rule walker when a `:decide` rule fires.
  """
  def invoke(decider, %Context{} = context, %Request{} = request, timeout) when is_integer(timeout) do
    do_invoke(decider, context, request, timeout)
  end

  @doc """
  Runs the policy's decide rule (if any) and applies the per-session
  decision cache. Used by the K8s control bridge when the sidecar
  sends a `decision_request`. Returns `{decision, updated_cache}`.
  """
  def decide(%NetworkPolicy{} = policy, %Context{} = context, %Request{} = request, cache) do
    case find_decide_rule(policy) do
      nil -> {default_decision(policy), cache}
      decider -> dispatch(decider, policy, context, request, cache)
    end
  end

  defp find_decide_rule(%NetworkPolicy{rules: rules}) do
    Enum.find_value(rules, fn
      {:decide, callable} -> callable
      _ -> nil
    end)
  end

  defp dispatch(decider, %NetworkPolicy{decision_cache: false} = policy, context, request, cache) do
    {run_one(decider, policy, context, request), cache}
  end

  defp dispatch(decider, policy, context, request, cache) do
    case Map.fetch(cache, request.host) do
      {:ok, cached} ->
        {cached, cache}

      :error ->
        decision = run_one(decider, policy, context, request)
        {decision, Map.put(cache, request.host, decision)}
    end
  end

  defp run_one(decider, policy, context, request) do
    case do_invoke(decider, context, request, policy.decide_timeout) do
      :allow -> :allow
      {:deny, _} = decision -> decision
      _other -> emit_failure_and_default(:decider_bad_return, policy)
    end
  end

  defp do_invoke(decider, context, request, timeout) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = run_decider(decider, context, request)
        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        validate(result)

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        emit_failure(:decider_error)
        {:deny, :decider_error}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          0 -> :ok
        end

        emit_failure(:decider_timeout)
        {:deny, :decider_timeout}
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

  defp validate(:allow), do: :allow
  defp validate({:deny, _reason} = decision), do: decision

  defp validate(_other) do
    emit_failure(:decider_bad_return)
    {:deny, :decider_bad_return}
  end

  defp default_decision(%NetworkPolicy{default: :allow}), do: :allow
  defp default_decision(%NetworkPolicy{default: :deny}), do: {:deny, :default_deny}

  defp emit_failure(reason) do
    :telemetry.execute(
      [:condukt, :sandbox, :network_policy, :decider_failure],
      %{count: 1},
      %{reason: reason}
    )
  end

  defp emit_failure_and_default(reason, policy) do
    emit_failure(reason)
    default_decision(policy)
  end
end

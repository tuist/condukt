defmodule Condukt.Sandbox.Net.Decider do
  @moduledoc """
  Behaviour and runtime for `Condukt.Sandbox.Net.Rule.Decide`.

  A decider receives a `Condukt.Sandbox.Net.Context` and a
  `Condukt.Sandbox.Net.Request` and returns `:allow` or
  `{:deny, reason}`. Three shapes are accepted when configuring a
  `Rule.Decide` entry on the policy pipeline:

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
  request is denied and an entry surfaces in telemetry.

  Decisions are cached per-session per-host when
  `Policy.decision_cache` is true (default). The cache is in-process
  and dies with the session. Pass `false` to invoke the decider on
  every connection.
  """

  alias Condukt.Sandbox.Net.Context
  alias Condukt.Sandbox.Net.Policy
  alias Condukt.Sandbox.Net.Request

  @doc """
  Implementations receive a `Condukt.Sandbox.Net.Context`, the
  `Condukt.Sandbox.Net.Request` the workspace is about to make, and the
  caller-supplied opts (a keyword list). They must return `:allow` to
  let the request through or `{:deny, reason}` to RST it at the
  sidecar, where `reason` is anything renderable for the event log.
  """
  @callback decide(context :: Context.t(), request :: Request.t(), opts :: keyword()) ::
              :allow | {:deny, term()}

  @doc """
  Invokes a decider once, in an isolated process with the policy's
  timeout. Used by `Condukt.Sandbox.Net.Rule.Decide`.

  `decider` is one of the three shapes documented above.
  """
  def invoke(decider, %Context{} = context, %Request{} = request, opts) do
    timeout = Keyword.get(opts, :decide_timeout, 5_000)
    do_invoke(decider, context, request, timeout)
  end

  @doc """
  Runs the policy's decide rule (if any) for the given request,
  applying the per-session decision cache.

  This is the entry point the K8s control bridge uses when the sidecar
  sends a `decision_request`. Returns `{decision, updated_cache}`.
  """
  def decide(%Policy{} = policy, %Context{} = context, %Request{} = request, cache) do
    case find_decide_rule(policy) do
      nil -> {default_decision(policy), cache}
      decider -> dispatch(decider, policy, context, request, cache)
    end
  end

  defp dispatch(decider, %Policy{decision_cache: false} = policy, context, request, cache) do
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

  defp find_decide_rule(%Policy{rules: rules}) do
    Enum.find_value(rules, fn entry ->
      {mod, opts} = normalise(entry)

      if mod == Condukt.Sandbox.Net.Rule.Decide do
        resolve_decider(opts)
      end
    end)
  end

  defp normalise({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  defp normalise(mod) when is_atom(mod), do: {mod, []}

  defp resolve_decider(opts) do
    cond do
      fun = Keyword.get(opts, :fun) -> fun
      mf = Keyword.get(opts, :mf) -> mf
      mod = Keyword.get(opts, :module) -> {mod, Keyword.get(opts, :opts, [])}
      true -> nil
    end
  end

  defp run_one(decider, policy, context, request) do
    case do_invoke(decider, context, request, policy.decide_timeout) do
      :allow -> :allow
      {:deny, _} = decision -> decision
      :continue -> {:deny, :decider_continue}
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
  defp validate(:continue), do: :continue

  defp validate(_other) do
    emit_failure(:decider_bad_return)
    {:deny, :decider_bad_return}
  end

  defp default_decision(%Policy{default: :allow}), do: :allow
  defp default_decision(%Policy{default: :deny}), do: {:deny, :default_deny}

  defp emit_failure(reason) do
    :telemetry.execute(
      [:condukt, :sandbox, :net, :decider_failure],
      %{count: 1},
      %{reason: reason}
    )
  end

  defp emit_failure_and_default(reason, policy) do
    emit_failure(reason)
    default_decision(policy)
  end
end

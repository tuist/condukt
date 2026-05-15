defmodule Condukt.Sandbox.Net.Policy do
  @moduledoc """
  Per-session egress policy expressed as an ordered list of rules.

  The shape is close to a `Plug` pipeline. For every outbound request
  the workspace makes, the runtime walks `:rules` in order. Each rule
  returns `:allow`, `{:deny, reason}`, or `:continue`. The first
  non-`:continue` answer wins. If every rule passes, the policy's
  `:default` action applies.

      %Condukt.Sandbox.Net.Policy{
        rules: [
          {Condukt.Sandbox.Net.Rule.DenyHosts, hosts: ["*.internal.example.com"]},
          {Condukt.Sandbox.Net.Rule.AllowHosts, hosts: ["api.github.com", "*.openai.com"]},
          {Condukt.Sandbox.Net.Rule.Decide, module: Condukt.Sandbox.Net.AgentDecider, opts: [agent: MyApp.NetGuard]}
        ],
        default: :deny
      }

  Each entry in `:rules` is either a module (instantiated with empty
  opts) or a `{module, opts}` tuple. The module must implement the
  `Condukt.Sandbox.Net.Rule` behaviour.

  ## Fields

    * `:rules` — the ordered list described above. Defaults to `[]`,
      which means every request falls through to `:default`.
    * `:default` — `:allow` or `:deny`. Default `:deny` so the policy
      fails closed.
    * `:decide_timeout` — milliseconds the `Rule.Decide` runtime waits
      for a decider call before treating it as failed. Default `5_000`.
    * `:redact` — list of regular expressions; matching content in
      request/response bodies and headers is redacted by the sidecar
      before events are emitted.
    * `:max_body_capture` — maximum bytes of body to retain in each
      event. Default `4096`. Set `0` to disable body capture.
    * `:context_messages` — maximum number of recent session messages
      to include in the `Condukt.Sandbox.Net.Context` handed to a
      decider rule. Default `5`.
    * `:context_metadata` — per-session static metadata attached to
      every decider invocation.
    * `:decision_cache` — `true` (default) to cache decider answers
      per-session per-host; `false` to invoke the decider on every
      connection.

  ## Telemetry

  Every request flowing through the sidecar emits the following
  telemetry events on the BEAM side:

    * `[:condukt, :sandbox, :net, :request_opened]`
    * `[:condukt, :sandbox, :net, :request_allowed]`
    * `[:condukt, :sandbox, :net, :request_denied]`
    * `[:condukt, :sandbox, :net, :request_closed]`

  Measurements: `%{bytes_in: integer, bytes_out: integer}`. Metadata:
  `%{request: Condukt.Sandbox.Net.Request.t(), reason: atom() | binary() | nil}`.
  See `guides/net.md` for usage patterns.
  """

  defstruct rules: [],
            default: :deny,
            decide_timeout: 5_000,
            redact: [],
            max_body_capture: 4096,
            context_messages: 5,
            context_metadata: %{},
            decision_cache: true

  @doc """
  Normalises arbitrary policy input into a `t()`.

  Accepts a `t()`, a keyword list, a map, or `nil` (returns the default
  deny-all policy).
  """
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = policy), do: policy

  def new(opts) when is_list(opts) or is_map(opts) do
    fields = Map.new(opts)

    %__MODULE__{
      rules: Map.get(fields, :rules, []),
      default: Map.get(fields, :default, :deny),
      decide_timeout: Map.get(fields, :decide_timeout, 5_000),
      redact: Map.get(fields, :redact, []),
      max_body_capture: Map.get(fields, :max_body_capture, 4096),
      context_messages: Map.get(fields, :context_messages, 5),
      context_metadata: Map.get(fields, :context_metadata, %{}),
      decision_cache: Map.get(fields, :decision_cache, true)
    }
  end

  @doc """
  Walks the policy's rule pipeline against a context + request.

  Returns `:allow` or `{:deny, reason}`. The reason from a deny rule
  is propagated verbatim; if the pipeline falls through, the reason is
  `:default_deny` (when `:default` is `:deny`).
  """
  def evaluate(%__MODULE__{} = policy, context, request) do
    walk(policy.rules, context, request, policy)
  end

  defp walk([], _context, _request, %__MODULE__{default: :allow}), do: :allow
  defp walk([], _context, _request, %__MODULE__{default: :deny}), do: {:deny, :default_deny}

  defp walk([entry | rest], context, request, policy) do
    {mod, opts} = normalise(entry)

    case mod.evaluate(context, request, opts) do
      :continue -> walk(rest, context, request, policy)
      :allow -> :allow
      {:deny, _reason} = decision -> decision
      :deny -> {:deny, :rule_deny}
      other -> raise ArgumentError, "rule #{inspect(mod)} returned #{inspect(other)}"
    end
  end

  defp normalise({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  defp normalise(mod) when is_atom(mod), do: {mod, []}
end

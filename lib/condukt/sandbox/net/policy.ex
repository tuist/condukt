defmodule Condukt.Sandbox.Net.Policy do
  @moduledoc """
  Per-session egress policy.

  Every outbound HTTP request the agent makes runs through the policy
  pipeline in order:

    1. `:deny_hosts` — if the parsed hostname matches any glob in the
      deny list, the connection is RST at SNI immediately. Final.
    2. `:allow_hosts` — if the hostname matches any glob in the allow
      list, the connection proceeds with no further checks. Use for
      hostnames you trust unconditionally for this session.
    3. `:decide` — if set, the request and a session-context snapshot
      are sent to the decider (function, MFA tuple, or `{module, opts}`
      pair). The decider returns `:allow` or `{:deny, reason}`. On
      timeout (`:decide_timeout`, default 5000ms) or error the
      `:default` action applies.
    4. `:default` — `:allow` or `:deny`. Applied when none of the above
      matched. Defaults to `:deny` so the policy fails closed.

  Fields:

    * `:allow_hosts` — list of host glob patterns. `"*"` matches one
      DNS label; `"**"` matches one or more labels.
    * `:deny_hosts` — list of host glob patterns, evaluated before
      `:allow_hosts`.
    * `:decide` — decider callable. Accepts:
      - a 2-arity function `(context, request) -> :allow | {:deny, reason}`
      - a `{module, function}` tuple called as `module.function(context, request)`
      - a `{module, opts}` tuple for behaviour-backed deciders;
        `module.decide(context, request, opts)` is invoked. The
        Condukt-shipped `Condukt.Sandbox.Net.AgentDecider` wraps a
        `Condukt`-defined agent module as a decider.
    * `:decide_timeout` — milliseconds before the decider call is
      considered failed. Default `5_000`.
    * `:default` — `:allow` or `:deny`. Default `:deny`.
    * `:redact` — list of regular expressions; matching content in
      request/response bodies and headers is redacted by the sidecar
      before events are emitted.
    * `:max_body_capture` — maximum bytes of request/response body to
      retain in each event (default `4096`). Set `0` to disable body
      capture.
    * `:context_messages` — maximum number of recent messages to
      include in the decider's `Condukt.Sandbox.Net.Context`. Default
      `5`.
    * `:context_metadata` — per-session static metadata to attach to
      every decider invocation. Map.
    * `:decision_cache` — `true` (default) to cache decisions
      per-session per-host; `false` to invoke the decider on every
      connection.
    * `:sink` — `Condukt.Sandbox.Net.Sink` reference for delivering
      events. Defaults to `Condukt.Sandbox.Net.Sink.Log`.

  Enforcement at the egress sidecar: failing the policy at any step
  (deny list, decider deny, default deny) closes the connection at the
  TCP layer before TLS termination. The workspace sees a connection
  reset.
  """

  defstruct allow_hosts: [],
            deny_hosts: [],
            decide: nil,
            decide_timeout: 5_000,
            default: :deny,
            redact: [],
            max_body_capture: 4096,
            context_messages: 5,
            context_metadata: %{},
            decision_cache: true,
            sink: Condukt.Sandbox.Net.Sink.Log

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
      allow_hosts: Map.get(fields, :allow_hosts, []),
      deny_hosts: Map.get(fields, :deny_hosts, []),
      decide: Map.get(fields, :decide),
      decide_timeout: Map.get(fields, :decide_timeout, 5_000),
      default: Map.get(fields, :default, :deny),
      redact: Map.get(fields, :redact, []),
      max_body_capture: Map.get(fields, :max_body_capture, 4096),
      context_messages: Map.get(fields, :context_messages, 5),
      context_metadata: Map.get(fields, :context_metadata, %{}),
      decision_cache: Map.get(fields, :decision_cache, true),
      sink: Map.get(fields, :sink, Condukt.Sandbox.Net.Sink.Log)
    }
  end

  @doc """
  Evaluates a host name against the static portion of the policy
  (`:deny_hosts`, `:allow_hosts`, `:default`). Does not invoke the
  decider — that runs separately via `Condukt.Sandbox.Net.Decider`.

  Returns `:allow`, `:decide` (the caller should run the decider), or
  `{:deny, reason}` where reason is one of `:matched_deny_list`,
  `:no_allow_match`, or `:default_deny`.
  """
  def evaluate(%__MODULE__{} = policy, host) when is_binary(host) do
    cond do
      matches_any?(host, policy.deny_hosts) ->
        {:deny, :matched_deny_list}

      matches_any?(host, policy.allow_hosts) ->
        :allow

      policy.decide != nil ->
        :decide

      true ->
        case policy.default do
          :allow -> :allow
          :deny -> {:deny, default_deny_reason(policy)}
        end
    end
  end

  defp default_deny_reason(%__MODULE__{allow_hosts: []}), do: :default_deny
  defp default_deny_reason(%__MODULE__{}), do: :no_allow_match

  @doc """
  Returns whether `host` matches any of the given glob patterns.

  Glob syntax:

    * `*` matches a single DNS label (no dots).
    * `**` matches one or more dot-separated labels.
    * Literal characters match themselves; comparison is case-insensitive.
  """
  def matches_any?(host, patterns) when is_binary(host) and is_list(patterns) do
    Enum.any?(patterns, &matches?(host, &1))
  end

  @doc "Single-pattern match. See `matches_any?/2` for syntax."
  def matches?(host, pattern) when is_binary(host) and is_binary(pattern) do
    host = String.downcase(host)
    pattern = String.downcase(pattern)
    regex = compile_pattern(pattern)
    Regex.match?(regex, host)
  end

  defp compile_pattern(pattern) do
    parts =
      pattern
      |> String.graphemes()
      |> tokenize([], [])
      |> Enum.reverse()

    body = Enum.map_join(parts, &token_to_regex/1)

    Regex.compile!("^" <> body <> "$")
  end

  defp tokenize([], current, acc) do
    flush(current, acc)
  end

  defp tokenize(["*", "*" | rest], current, acc) do
    acc = flush(current, acc)
    tokenize(rest, [], [:doublestar | acc])
  end

  defp tokenize(["*" | rest], current, acc) do
    acc = flush(current, acc)
    tokenize(rest, [], [:star | acc])
  end

  defp tokenize([ch | rest], current, acc) do
    tokenize(rest, [ch | current], acc)
  end

  defp flush([], acc), do: acc
  defp flush(current, acc), do: [{:literal, current |> Enum.reverse() |> Enum.join()} | acc]

  defp token_to_regex(:star), do: "[^.]+"
  defp token_to_regex(:doublestar), do: ".+"
  defp token_to_regex({:literal, str}), do: Regex.escape(str)
end

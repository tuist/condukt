defmodule Condukt.Sandbox.Net.Policy do
  @moduledoc """
  Per-session egress policy.

  A policy declares:

    * `:allow_hosts` — list of host glob patterns. `"*"` matches any single
      DNS label; `"**"` matches multiple labels. `"api.github.com"`,
      `"*.openai.com"`, and `"**.googleapis.com"` are all valid.
    * `:deny_hosts` — list of host glob patterns evaluated before
      `:allow_hosts`. A request matching a deny pattern is rejected even
      if it would also match an allow pattern.
    * `:default` — `:allow` or `:deny`. The action taken when neither list
      matches. Defaults to `:deny` to fail closed.
    * `:redact` — list of regular expressions; request/response body and
      header values that match are redacted by the sidecar before events
      are emitted. Has no effect on Tier 1 (SNI-only) capture.
    * `:max_body_capture` — maximum number of bytes of request/response
      body to retain in each event (default `4096`). Set `0` to disable
      body capture even on Tier 2.
    * `:sink` — `Condukt.Sandbox.Net.Sink` reference: a `pid()`, a
      registered name, or `{module, opts}` for a behaviour-backed sink.
      Defaults to `Condukt.Sandbox.Net.Sink.Log`.

  Policy is enforced at two layers: the egress sidecar refuses connections
  that fail the host evaluation (RST at SNI), and the BEAM-side decoder
  surfaces the outcome as `:request_denied` events for auditing.
  """

  defstruct allow_hosts: [],
            deny_hosts: [],
            default: :deny,
            redact: [],
            max_body_capture: 4096,
            sink: Condukt.Sandbox.Net.Sink.Log

  @doc """
  Normalises arbitrary policy input into a `t()`.

  Accepts:

    * a `t()` (returned as-is)
    * a keyword list (`[allow_hosts: [...], default: :allow]`)
    * a map (`%{allow_hosts: [...]}`)
    * `nil` (returns the default deny-all policy)
  """
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = policy), do: policy

  def new(opts) when is_list(opts) or is_map(opts) do
    fields = Map.new(opts)

    %__MODULE__{
      allow_hosts: Map.get(fields, :allow_hosts, []),
      deny_hosts: Map.get(fields, :deny_hosts, []),
      default: Map.get(fields, :default, :deny),
      redact: Map.get(fields, :redact, []),
      max_body_capture: Map.get(fields, :max_body_capture, 4096),
      sink: Map.get(fields, :sink, Condukt.Sandbox.Net.Sink.Log)
    }
  end

  @doc """
  Evaluates a host name against the policy.

  Returns `:allow` or `{:deny, reason}` where reason is one of
  `:matched_deny_list`, `:no_allow_match`, or `:default_deny`.
  """
  def evaluate(%__MODULE__{} = policy, host) when is_binary(host) do
    cond do
      matches_any?(host, policy.deny_hosts) ->
        {:deny, :matched_deny_list}

      policy.allow_hosts == [] ->
        case policy.default do
          :allow -> :allow
          :deny -> {:deny, :default_deny}
        end

      matches_any?(host, policy.allow_hosts) ->
        :allow

      true ->
        case policy.default do
          :allow -> :allow
          :deny -> {:deny, :no_allow_match}
        end
    end
  end

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

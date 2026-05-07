# Telemetry

Condukt emits `:telemetry` events for the major phases of an agent run.
Attach handlers to feed your existing observability stack: Logger,
`telemetry_metrics`, Prometheus, OpenTelemetry, or anything else.

## Events

| Event | Measurements | Metadata |
| ----- | ------------ | -------- |
| `[:condukt, :agent, :start]` | `system_time` | `:agent`, `:session_id` |
| `[:condukt, :agent, :stop]` | `duration` | `:agent`, `:session_id` |
| `[:condukt, :tool_call, :start]` | `system_time` | `:tool`, `:agent`, `:session_id` |
| `[:condukt, :tool_call, :stop]` | `duration` | `:tool`, `:agent`, `:session_id` |
| `[:condukt, :subagent, :start]` | `system_time` | `:agent`, `:role`, `:child_agent`, `:input?`, `:output?`, `:parent_session_id` |
| `[:condukt, :subagent, :stop]` | `duration` | `:agent`, `:role`, `:child_agent`, `:input?`, `:output?`, `:status`, `:error`, `:parent_session_id`, `:session_id` |
| `[:condukt, :operation, :start]` | `system_time` | `:agent`, `:operation`, `:session_id` |
| `[:condukt, :operation, :stop]` | `duration` | `:agent`, `:operation`, `:session_id` |
| `[:condukt, :run, :start]` | `system_time` | `:structured?`, `:input?`, `:session_id` |
| `[:condukt, :run, :stop]` | `duration` | `:structured?`, `:input?`, `:session_id` |
| `[:condukt, :compact, :stop]` | `duration`, `before`, `after` | `:agent`, `:session_id` |
| `[:condukt, :secrets, :resolve]` | `count` | `:agent`, `:names`, `:session_id` |
| `[:condukt, :secrets, :access]` | `count` | `:agent`, `:tool`, `:tool_call_id`, `:names`, `:session_id` |

The exact set may grow over time. Attach broadly with `attach_many/4` so
new events surface in your handlers without code changes.

## Session ids

Every event emitted from a `Condukt.Session` (or a runtime entry point that
spins up a transient one) carries a `:session_id` in metadata. Sessions
generate a UUIDv7 at startup unless the caller passes an explicit `:id`
option to `Condukt.start_link/2` or `Condukt.run/2`. UUIDv7 ids are
time-ordered, so persisting them keeps storage and indexes aligned with
chronological order.

Use `:session_id` to group all events emitted by a single agentic run, for
example to persist a per-run audit trail. `Condukt.run/2` and
`Condukt.Operation.run/4` generate the id once and reuse it for both their
wrapping `:run` / `:operation` events and the inner agent and tool events.

Sub-agent delegation events expose both ids: `:parent_session_id` is the
session that called the subagent tool, and `:session_id` (on `:stop`) is
the child session created by the delegation. This lets observability tools
reconstruct full parent/child traces.

Secret events are value-free. `:names` contains environment variable names
such as `["GH_TOKEN"]`, never the resolved secret values. `:tool_call_id` is
present when the access comes from a provider-returned tool call.

Sub-agent events are value-free too. They identify the parent agent module,
the delegated role, the child agent module, whether structured input and output
contracts are configured, and whether delegation ended with `:ok` or `:error`.
The `:error` metadata is an atom such as `:invalid_input`, not the rejected
input or output payload.

## Attaching a handler

```elixir
:telemetry.attach_many(
  "condukt-logger",
  [
    [:condukt, :agent, :start],
    [:condukt, :agent, :stop],
    [:condukt, :tool_call, :start],
    [:condukt, :tool_call, :stop],
    [:condukt, :subagent, :start],
    [:condukt, :subagent, :stop],
    [:condukt, :operation, :start],
    [:condukt, :operation, :stop],
    [:condukt, :run, :start],
    [:condukt, :run, :stop],
    [:condukt, :compact, :stop],
    [:condukt, :secrets, :resolve],
    [:condukt, :secrets, :access]
  ],
  fn event, measurements, metadata, _config ->
    Logger.info("#{inspect(event)} #{inspect(measurements)} #{inspect(metadata)}")
  end,
  nil
)
```

Attach this once at application start.

## With `telemetry_metrics`

```elixir
def metrics do
  [
    summary("condukt.agent.stop.duration",
      unit: {:native, :millisecond}
    ),
    summary("condukt.tool_call.stop.duration",
      tags: [:tool],
      unit: {:native, :millisecond}
    ),
    counter("condukt.tool_call.stop.count", tags: [:tool]),
    summary("condukt.subagent.stop.duration", tags: [:agent, :role, :child_agent, :status]),
    counter("condukt.subagent.stop.count", tags: [:agent, :role, :child_agent, :status]),
    counter("condukt.secrets.access.count", tags: [:agent, :tool])
  ]
end
```

## Tracing tool calls

Tool call start and stop events share an implicit span via the `:telemetry`
span helpers. With OpenTelemetry you can wrap them with a span processor
that turns each `[:condukt, :tool_call, :*]` pair into a span keyed by the
`:tool` metadata.

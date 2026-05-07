defmodule Condukt.Telemetry do
  @moduledoc """
  Telemetry integration for Condukt.

  Condukt emits telemetry events that can be used for monitoring,
  logging, and observability.

  ## Events

  Every event emitted from a `Condukt.Session` (and the runtime entry points
  that spin one up) carries a `:session_id` field in metadata. Sessions
  generate a UUIDv7 on start unless the caller supplies an `:id` option;
  downstream consumers can use it to correlate every event for a single run
  in their observability stack. See `guides/telemetry.md` for details.

  ### Agent Events

  - `[:condukt, :agent, :start]` - Agent started processing a prompt
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{agent: module, session_id: String.t()}`

  - `[:condukt, :agent, :stop]` - Agent finished processing
    - Measurements: `%{duration: integer}`
    - Metadata: `%{agent: module, session_id: String.t()}`

  - `[:condukt, :agent, :exception]` - Agent raised an exception
    - Measurements: `%{duration: integer}`
    - Metadata: `%{agent: module, session_id: String.t(), kind: atom, reason: term, stacktrace: list}`

  ### Tool Events

  - `[:condukt, :tool_call, :start]` - Tool call started
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{tool: string, agent: module, session_id: String.t()}`

  - `[:condukt, :tool_call, :stop]` - Tool call completed
    - Measurements: `%{duration: integer}`
    - Metadata: `%{tool: string, agent: module, session_id: String.t()}`

  - `[:condukt, :tool_call, :exception]` - Tool call raised an exception
    - Measurements: `%{duration: integer}`
    - Metadata: `%{tool: string, agent: module, session_id: String.t(), kind: atom, reason: term, stacktrace: list}`

  ### Sub-agent Events

  These events wrap the explicit sub-agent delegation lifecycle. They do not
  include task text, structured input values, or structured output values.

  - `[:condukt, :subagent, :start]` - Sub-agent delegation started
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{agent: module | pid, role: atom, child_agent: module, input?: boolean, output?: boolean, parent_session_id: String.t() | nil}`

  - `[:condukt, :subagent, :stop]` - Sub-agent delegation finished
    - Measurements: `%{duration: integer}`
    - Metadata: `%{agent: module | pid, role: atom, child_agent: module, input?: boolean, output?: boolean, status: :ok | :error, parent_session_id: String.t() | nil, session_id: String.t() | nil}`
    - Error metadata: `%{error: atom}`

  `:parent_session_id` is the calling session's id; `:session_id` (only on
  `:stop`) is the child session's id, present when the child started
  successfully.

  ### Secret Events

  These events never include secret values.

  - `[:condukt, :secrets, :resolve]` - Session secrets resolved
    - Measurements: `%{count: non_neg_integer}`
    - Metadata: `%{agent: module, names: [String.t()], session_id: String.t()}`

  - `[:condukt, :secrets, :access]` - A tool received resolved session secrets
    - Measurements: `%{count: non_neg_integer}`
    - Metadata: `%{agent: module, tool: String.t(), names: [String.t()], session_id: String.t()}`
    - Optional metadata: `%{tool_call_id: String.t()}`

  ### Operation Events

  Wrap a full `Condukt.Operation.run/4` call (input validation, transient
  session run, output validation). The inner LLM loop still emits the
  `[:condukt, :agent, ...]` events for free.

  - `[:condukt, :operation, :start]` - Operation invocation started
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{agent: module, operation: atom, session_id: String.t()}`

  - `[:condukt, :operation, :stop]` - Operation invocation finished
    - Measurements: `%{duration: integer}`
    - Metadata: `%{agent: module, operation: atom, session_id: String.t()}`

  - `[:condukt, :operation, :exception]` - Operation raised an exception
    - Measurements: `%{duration: integer}`
    - Metadata: `%{agent: module, operation: atom, session_id: String.t(), kind: atom, reason: term, stacktrace: list}`

  ### Anonymous Run Events

  Wrap a `Condukt.run/2` call (the runtime entry point that does not require
  an agent module). The inner agent and tool events still fire for free.

  - `[:condukt, :run, :start]` - Anonymous run started
    - Measurements: `%{system_time: integer}`
    - Metadata: `%{structured?: boolean, input?: boolean, session_id: String.t()}`

  - `[:condukt, :run, :stop]` - Anonymous run finished
    - Measurements: `%{duration: integer}`
    - Metadata: `%{structured?: boolean, input?: boolean, session_id: String.t()}`

  - `[:condukt, :run, :exception]` - Anonymous run raised an exception
    - Measurements: `%{duration: integer}`
    - Metadata: `%{structured?: boolean, input?: boolean, session_id: String.t(), kind: atom, reason: term, stacktrace: list}`

  ## Example: Attaching Handlers

      :telemetry.attach_many(
        "my-agent-handler",
        [
          [:condukt, :agent, :start],
          [:condukt, :agent, :stop],
          [:condukt, :tool_call, :stop],
          [:condukt, :subagent, :start],
          [:condukt, :subagent, :stop],
          [:condukt, :secrets, :resolve],
          [:condukt, :secrets, :access]
        ],
        &MyApp.Telemetry.handle_event/4,
        nil
      )
  """

  @doc """
  Executes a function within a telemetry span.

  Emits start, stop, and exception events for the given event name.
  """
  def span(event, metadata, fun) when is_atom(event) and is_map(metadata) and is_function(fun, 0) do
    event_prefix = [:condukt, event]
    start_time = System.monotonic_time()

    :telemetry.execute(
      event_prefix ++ [:start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = fun.()

      :telemetry.execute(
        event_prefix ++ [:stop],
        %{duration: System.monotonic_time() - start_time},
        metadata
      )

      result
    catch
      kind, reason ->
        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, %{
            kind: kind,
            reason: reason,
            stacktrace: __STACKTRACE__
          })
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Emits a telemetry event.
  """
  def emit(event, measurements \\ %{}, metadata \\ %{})

  def emit(event, measurements, metadata) when is_atom(event) do
    emit([event], measurements, metadata)
  end

  def emit(event, measurements, metadata) when is_list(event) do
    :telemetry.execute([:condukt | event], measurements, metadata)
  end
end

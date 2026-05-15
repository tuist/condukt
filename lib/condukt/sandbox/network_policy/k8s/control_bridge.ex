defmodule Condukt.Sandbox.NetworkPolicy.K8s.ControlBridge do
  @moduledoc false

  # GenServer that owns the bidirectional NDJSON control channel between
  # the BEAM and the sidecar `condukt-egress` proxy running in a session
  # pod.
  #
  # We piggyback on the K8s `pods/exec` websocket the rest of the K8s
  # sandbox already uses, instead of implementing a fresh
  # `pods/portforward` client. The BEAM execs
  # `condukt-egress control-bridge` inside the sidecar container; the
  # subcommand pumps stdin/stdout against the proxy's control TCP port
  # on `127.0.0.1:15002` in the sidecar's network namespace.
  #
  # Stdout from the exec'd process is the sidecar's outbound NDJSON
  # stream (events + decision_requests). Stdin is the BEAM's responses
  # (decisions). The `:k8s` library's exec helper provides both halves.
  #
  # Per-host decision caching, decider invocation, telemetry emission,
  # and context assembly all live here. The owning K8s sandbox starts one
  # bridge per session at init and tears it down on shutdown.

  use GenServer

  alias Condukt.Sandbox.NetworkPolicy
  alias Condukt.Sandbox.NetworkPolicy.Context
  alias Condukt.Sandbox.NetworkPolicy.Decider
  alias Condukt.Sandbox.NetworkPolicy.Event
  alias Condukt.Sandbox.NetworkPolicy.Request

  @sidecar_container Condukt.Sandbox.NetworkPolicy.K8s.Manifests.sidecar_container_name()

  # ============================================================================
  # API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000), else: :ok
  end

  # ============================================================================
  # GenServer
  # ============================================================================

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    namespace = Keyword.fetch!(opts, :namespace)
    pod_name = Keyword.fetch!(opts, :pod_name)
    session_id = Keyword.fetch!(opts, :session_id)
    policy = Keyword.fetch!(opts, :policy)
    owner_pid = Keyword.get(opts, :owner_pid)

    Process.flag(:trap_exit, true)

    parent = self()
    ref = make_ref()
    {collector_pid, collector_ref} = spawn_monitor(fn -> collector_loop(parent, ref) end)

    op =
      K8s.Client.connect(
        "v1",
        "pods/exec",
        [namespace: namespace, name: pod_name],
        command: ["condukt-egress", "control-bridge"],
        container: @sidecar_container,
        tty: false
      )

    case K8s.Client.stream_to(conn, op, [recv_timeout: :infinity], collector_pid) do
      {:ok, send_fn} ->
        state = %{
          session_id: session_id,
          policy: policy,
          owner_pid: owner_pid,
          send_fn: send_fn,
          collector_pid: collector_pid,
          collector_ref: collector_ref,
          buffer: "",
          cache: %{}
        }

        {:ok, state}

      {:error, reason} ->
        require Logger

        Logger.warning(fn -> "[sandbox.network_policy.k8s] control bridge exec failed: #{inspect(reason)}" end)
        {:stop, {:exec_failed, reason}}
    end
  end

  @impl true
  def handle_info({:control_bridge_data, data}, state) do
    {state, lines} = drain_lines(state, data)
    state = Enum.reduce(lines, state, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({:control_bridge_eof}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{collector_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.send_fn, do: state.send_fn.(:close)
    :ok
  end

  # ============================================================================
  # Collector
  # ============================================================================

  defp collector_loop(parent, ref) do
    receive do
      {:open, true} ->
        collector_loop(parent, ref)

      {:stdout, data} when is_binary(data) ->
        send(parent, {:control_bridge_data, data})
        collector_loop(parent, ref)

      {:stderr, data} when is_binary(data) ->
        require Logger

        Logger.debug(fn -> "[sandbox.network_policy.k8s] bridge stderr: #{inspect(data)}" end)
        collector_loop(parent, ref)

      :close ->
        send(parent, {:control_bridge_eof})

      :exit ->
        send(parent, {:control_bridge_eof})

      {:exit, _code} ->
        send(parent, {:control_bridge_eof})

      _ ->
        collector_loop(parent, ref)
    end
  end

  # ============================================================================
  # Frame handling
  # ============================================================================

  defp drain_lines(state, data) do
    combined = state.buffer <> data

    case String.split(combined, "\n") do
      [single] -> {%{state | buffer: single}, []}
      parts -> {%{state | buffer: List.last(parts)}, Enum.drop(parts, -1)}
    end
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case JSON.decode(line) do
      {:ok, %{"type" => "event"} = frame} ->
        deliver_event(state.policy, frame)
        state

      {:ok, %{"type" => "decision_request"} = frame} ->
        respond_to_decision_request(state, frame)

      {:ok, other} ->
        require Logger

        Logger.warning(fn -> "[sandbox.network_policy.k8s] unknown frame type: #{inspect(other)}" end)
        state

      {:error, reason} ->
        require Logger

        Logger.warning(fn -> "[sandbox.network_policy.k8s] bad frame: #{inspect(reason)} line=#{inspect(line)}" end)
        state
    end
  end

  defp deliver_event(policy, frame) do
    with {:ok, request} <- Request.from_json(frame["request"] || %{}),
         {:ok, kind} <- decode_kind(frame["kind"]) do
      NetworkPolicy.deliver(policy, kind, request, reason: frame["reason"])
    end
  end

  defp decode_kind("request_opened"), do: {:ok, :request_opened}
  defp decode_kind("request_closed"), do: {:ok, :request_closed}
  defp decode_kind("request_allowed"), do: {:ok, :request_allowed}
  defp decode_kind("request_denied"), do: {:ok, :request_denied}
  defp decode_kind(other), do: {:error, {:invalid_kind, other}}

  defp respond_to_decision_request(state, %{"id" => id, "host" => host, "port" => port} = frame) do
    request = %Request{
      id: id,
      session_id: frame["session_id"] || state.session_id,
      host: host,
      port: port,
      scheme: frame["scheme"] || "https",
      started_at: DateTime.utc_now()
    }

    context = %Context{
      session_id: state.session_id,
      recent_messages: recent_messages(state),
      request: request,
      metadata: state.policy.context_metadata || %{}
    }

    {decision, cache} = Decider.decide(state.policy, context, request, state.cache)
    send_decision(state.send_fn, id, decision)
    %{state | cache: cache}
  end

  defp recent_messages(%{owner_pid: nil}), do: []

  defp recent_messages(%{owner_pid: pid, policy: %{context_messages: limit}}) when is_pid(pid) do
    if Process.alive?(pid), do: fetch_history(pid, limit), else: []
  end

  # Isolate the call: a session crash or timeout should not take the
  # bridge down with it. We spawn a probe process that does the
  # GenServer.call, then either get the result or fall through after a
  # bounded wait.
  defp fetch_history(pid, limit) do
    parent = self()
    ref = make_ref()

    {probe_pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          pid
          |> Condukt.Session.history()
          |> Enum.take(-limit)
          |> Enum.map(&serialise_message/1)

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^probe_pid, _reason} ->
        []
    after
      1_000 ->
        Process.exit(probe_pid, :kill)
        []
    end
  end

  defp serialise_message(%Condukt.Message{} = msg) do
    %{
      role: msg.role,
      content: Condukt.Message.text(msg),
      timestamp: msg.timestamp
    }
  end

  defp serialise_message(other), do: other

  defp send_decision(send_fn, id, :allow) do
    payload =
      JSON.encode!(%{
        type: "decision",
        id: id,
        action: "allow"
      }) <> "\n"

    send_fn.({:stdin, payload})
  end

  defp send_decision(send_fn, id, {:deny, reason}) do
    payload =
      JSON.encode!(%{
        type: "decision",
        id: id,
        action: "deny",
        reason: stringify_reason(reason)
      }) <> "\n"

    send_fn.({:stdin, payload})
  end

  defp stringify_reason(reason) when is_binary(reason), do: reason
  defp stringify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stringify_reason(reason), do: inspect(reason)

  # Public for tests
  @doc false
  def __decode_event_line__(line) do
    case JSON.decode(line) do
      {:ok, %{"type" => "event"} = frame} ->
        with {:ok, request} <- Request.from_json(frame["request"] || %{}),
             {:ok, kind} <- decode_kind(frame["kind"]) do
          {:ok, %Event{kind: kind, request: request, reason: frame["reason"], at: DateTime.utc_now()}}
        end

      other ->
        {:error, {:unexpected_frame, other}}
    end
  end
end

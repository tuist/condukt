defmodule Condukt.Sandbox.NetworkPolicy.K8s.ControlBridgeTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.NetworkPolicy
  alias Condukt.Sandbox.NetworkPolicy.Decider
  alias Condukt.Sandbox.NetworkPolicy.Event
  alias Condukt.Sandbox.NetworkPolicy.K8s.ControlBridge

  # The GenServer callbacks are plain functions over a map state, so we
  # can drive the frame-handling logic directly without a live
  # pods/exec channel. send_fn is injected to capture what the bridge
  # would have written to the sidecar's stdin.
  defp state(policy, test_pid, overrides \\ %{}) do
    send_fn = fn
      {:stdin, payload} -> send(test_pid, {:stdin, payload})
      :close -> send(test_pid, :closed)
    end

    Map.merge(
      %{
        session_id: "s1",
        policy: policy,
        decide_spec: Decider.policy_spec(policy),
        owner_pid: nil,
        connector: fn _owner -> {:error, :stub} end,
        max_reconnects: 10,
        pf: nil,
        pf_ref: make_ref(),
        send_fn: send_fn,
        buffer: "",
        cache: %{},
        attempts: 0
      },
      overrides
    )
  end

  defp event_frame(kind, host, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "event",
        "kind" => kind,
        "request" => %{
          "id" => "r1",
          "host" => host,
          "port" => 443,
          "started_at" => "2026-05-17T10:00:00Z"
        }
      },
      extra
    )
  end

  defp attach(event, test_pid) do
    id = {__MODULE__, event, make_ref()}

    :telemetry.attach(
      id,
      [:condukt, :sandbox, :network_policy, event],
      fn _name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "__decode_event_line__/1" do
    test "decodes an event with matched_rule provenance" do
      line =
        JSON.encode!(
          event_frame("request_denied", "evil.com", %{
            "reason" => "matched_deny_list",
            "matched_rule" => %{"index" => 1, "kind" => "deny"}
          })
        )

      assert {:ok, %Event{kind: :request_denied, matched_rule: %{index: 1, kind: :deny}}} =
               ControlBridge.__decode_event_line__(line)
    end

    test "decodes a request_failed event" do
      line = JSON.encode!(event_frame("request_failed", "api.github.com", %{"reason" => "tls_client_rejected_ca"}))

      assert {:ok, %Event{kind: :request_failed, reason: "tls_client_rejected_ca"}} =
               ControlBridge.__decode_event_line__(line)
    end

    test "rejects a non-event frame" do
      assert {:error, {:unexpected_frame, _}} =
               ControlBridge.__decode_event_line__(JSON.encode!(%{"type" => "decision_request"}))
    end
  end

  describe "handle_info/2 event frames" do
    test "delivers an event as telemetry, including matched_rule" do
      attach(:request_allowed, self())
      st = state(%NetworkPolicy{rules: [allow: ["api.github.com"]]}, self())

      line =
        JSON.encode!(
          event_frame("request_allowed", "api.github.com", %{
            "matched_rule" => %{"index" => 0, "kind" => "allow"}
          })
        )

      assert {:noreply, _st} = ControlBridge.handle_info({:control_bridge_data, line <> "\n"}, st)

      assert_receive {:telemetry, _measurements, metadata}
      assert metadata.request.host == "api.github.com"
      assert metadata.matched_rule == %{index: 0, kind: :allow}
    end

    test "buffers a partial line until the newline arrives" do
      attach(:request_closed, self())
      st = state(%NetworkPolicy{}, self())

      line = JSON.encode!(event_frame("request_closed", "api.github.com"))
      {head, tail} = String.split_at(line, 12)

      assert {:noreply, st} = ControlBridge.handle_info({:control_bridge_data, head}, st)
      assert st.buffer == head
      refute_received {:telemetry, _, _}

      assert {:noreply, st} = ControlBridge.handle_info({:control_bridge_data, tail <> "\n"}, st)
      assert st.buffer == ""
      assert_receive {:telemetry, _, _}
    end

    test "ignores an unknown frame type without crashing" do
      st = state(%NetworkPolicy{}, self())
      line = JSON.encode!(%{"type" => "mystery"})
      assert {:noreply, ^st} = ControlBridge.handle_info({:control_bridge_data, line <> "\n"}, st)
    end

    test "ignores a malformed JSON line without crashing" do
      st = state(%NetworkPolicy{}, self())
      assert {:noreply, ^st} = ControlBridge.handle_info({:control_bridge_data, "not json\n"}, st)
    end
  end

  describe "handle_info/2 decision_request frames" do
    defp decision_line(host) do
      JSON.encode!(%{
        "type" => "decision_request",
        "id" => "d1",
        "host" => host,
        "port" => 443,
        "scheme" => "https"
      }) <> "\n"
    end

    test "answers an allow decision on the sidecar stdin" do
      policy = %NetworkPolicy{rules: [decide: fn _ctx, _req -> :allow end]}
      st = state(policy, self())

      assert {:noreply, st} = ControlBridge.handle_info({:control_bridge_data, decision_line("api.example.com")}, st)

      assert_receive {:stdin, payload}
      assert String.ends_with?(payload, "\n")
      assert %{"type" => "decision", "id" => "d1", "action" => "allow"} = JSON.decode!(payload)
      assert st.cache == %{"api.example.com" => :allow}
    end

    test "answers a deny decision with a stringified reason" do
      policy = %NetworkPolicy{rules: [decide: fn _ctx, _req -> {:deny, :nope} end]}
      st = state(policy, self())

      assert {:noreply, _st} = ControlBridge.handle_info({:control_bridge_data, decision_line("evil.com")}, st)

      assert_receive {:stdin, payload}
      assert %{"action" => "deny", "reason" => "nope"} = JSON.decode!(payload)
    end

    test "caches the decision so the decider runs once per host" do
      counter = :counters.new(1, [])

      policy =
        %NetworkPolicy{
          rules: [
            decide: fn _ctx, _req ->
              :counters.add(counter, 1, 1)
              :allow
            end
          ]
        }

      st = state(policy, self())

      data = decision_line("api.example.com") <> decision_line("api.example.com")
      assert {:noreply, st} = ControlBridge.handle_info({:control_bridge_data, data}, st)

      assert :counters.get(counter, 1) == 1
      assert st.cache == %{"api.example.com" => :allow}
    end
  end

  describe "lifecycle / reconnect" do
    test "EOF schedules a reconnect instead of stopping" do
      st = state(%NetworkPolicy{}, self())
      assert {:noreply, st} = ControlBridge.handle_info({:control_bridge_eof}, st)
      assert st.pf == nil
      assert st.send_fn == nil
      assert_receive :reconnect, 1_000
    end

    test "the portforward going down schedules a reconnect" do
      st = state(%NetworkPolicy{}, self())
      msg = {:DOWN, st.pf_ref, :process, self(), :killed}
      assert {:noreply, _st} = ControlBridge.handle_info(msg, st)
      assert_receive :reconnect, 1_000
    end

    test ":reconnect re-establishes the channel via the connector" do
      pf = spawn(fn -> Process.sleep(:infinity) end)
      st = state(%NetworkPolicy{}, self(), %{connector: fn _owner -> {:ok, pf} end, pf: nil, send_fn: nil})

      assert {:noreply, st} = ControlBridge.handle_info(:reconnect, st)
      assert st.pf == pf
      assert is_function(st.send_fn, 1)
      assert st.attempts == 0
    end

    test ":reconnect backs off and retries while under the attempt cap" do
      st = state(%NetworkPolicy{}, self(), %{connector: fn _ -> {:error, :down} end, attempts: 0})
      assert {:noreply, st} = ControlBridge.handle_info(:reconnect, st)
      assert st.attempts == 1
      assert_receive :reconnect, 2_000
    end

    test ":reconnect stops the bridge once the attempt cap is hit" do
      st =
        state(%NetworkPolicy{}, self(), %{
          connector: fn _ -> {:error, :down} end,
          attempts: 9,
          max_reconnects: 10
        })

      assert {:stop, {:portforward_unrecoverable, :down}, _st} =
               ControlBridge.handle_info(:reconnect, st)
    end

    test "an unrelated message is ignored" do
      st = state(%NetworkPolicy{}, self())
      assert {:noreply, ^st} = ControlBridge.handle_info(:something_else, st)
    end

    test "terminate closes the channel" do
      st = state(%NetworkPolicy{}, self())
      assert :ok = ControlBridge.terminate(:normal, st)
      assert_received :closed
    end
  end
end

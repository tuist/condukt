defmodule Condukt.Sandbox.NetTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.Net
  alias Condukt.Sandbox.Net.{Event, Policy, Request}

  defp request(host) do
    %Request{
      id: "r-#{System.unique_integer([:positive])}",
      host: host,
      port: 443,
      tier: :sni,
      started_at: DateTime.utc_now()
    }
  end

  describe "evaluate/2" do
    test "respects host allowlist" do
      policy = %Policy{allow_hosts: ["api.github.com"], default: :deny}
      assert :allow = Net.evaluate(policy, request("api.github.com"))
      assert {:deny, _} = Net.evaluate(policy, request("evil.com"))
    end
  end

  describe "deliver/4 with process sink" do
    test "forwards events to the configured pid" do
      policy = %Policy{
        sink: {Condukt.Sandbox.Net.Sink.Process, to: self()}
      }

      :ok = Net.deliver(policy, :request_closed, request("api.github.com"))

      assert_receive {:condukt_sandbox_net_event,
                      %Event{kind: :request_closed, request: %Request{host: "api.github.com"}}}
    end

    test "carries the reason on denied events" do
      policy = %Policy{sink: {Condukt.Sandbox.Net.Sink.Process, to: self()}}

      :ok = Net.deliver(policy, :request_denied, request("evil.com"), reason: :no_allow_match)

      assert_receive {:condukt_sandbox_net_event, %Event{kind: :request_denied, reason: :no_allow_match}}
    end
  end

  describe "deliver/4 with pid sink" do
    test "sends events directly when sink is a pid" do
      policy = %Policy{sink: self()}

      :ok = Net.deliver(policy, :request_opened, request("api.github.com"))

      assert_receive {:condukt_sandbox_net_event, %Event{kind: :request_opened}}
    end
  end

  describe "deliver/4 with telemetry default sink" do
    test "emits a telemetry event with bytes measurements and request metadata" do
      test_pid = self()
      handler_id = "net-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:condukt, :sandbox, :net, :request_closed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      policy = Policy.new(nil)
      req = %{request("x.com") | bytes_in: 100, bytes_out: 50}

      :ok = Net.deliver(policy, :request_closed, req)

      assert_receive {:telemetry, %{bytes_in: 100, bytes_out: 50}, %{request: ^req}}
    end
  end
end

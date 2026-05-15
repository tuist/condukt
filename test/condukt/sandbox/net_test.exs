defmodule Condukt.Sandbox.NetTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.Net
  alias Condukt.Sandbox.Net.Policy
  alias Condukt.Sandbox.Net.Request
  alias Condukt.Sandbox.Net.Rule

  defp request(host) do
    %Request{
      id: "r-#{System.unique_integer([:positive])}",
      host: host,
      port: 443,
      started_at: DateTime.utc_now()
    }
  end

  describe "evaluate/2" do
    test "respects allow-list rule" do
      policy = %Policy{
        rules: [{Rule.AllowHosts, hosts: ["api.github.com"]}],
        default: :deny
      }

      assert :allow = Net.evaluate(policy, request("api.github.com"))
      assert {:deny, _} = Net.evaluate(policy, request("evil.com"))
    end
  end

  describe "deliver/4 telemetry" do
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

      req = %{request("x.com") | bytes_in: 100, bytes_out: 50}

      :ok = Net.deliver(nil, :request_closed, req)

      assert_receive {:telemetry, %{bytes_in: 100, bytes_out: 50}, %{request: ^req}}
    end

    test "passes :reason through metadata" do
      test_pid = self()
      handler_id = "net-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:condukt, :sandbox, :net, :request_denied],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok = Net.deliver(nil, :request_denied, request("evil.com"), reason: :no_allow_match)

      assert_receive {:telemetry, %{reason: :no_allow_match}}
    end
  end
end

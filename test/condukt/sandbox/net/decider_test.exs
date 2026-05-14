defmodule Condukt.Sandbox.Net.DeciderTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.Net.Context
  alias Condukt.Sandbox.Net.Decider
  alias Condukt.Sandbox.Net.Policy
  alias Condukt.Sandbox.Net.Request

  defp request(host \\ "evil.com") do
    %Request{id: "r1", host: host, port: 443, started_at: DateTime.utc_now()}
  end

  defp context(session_id \\ "s1") do
    %Context{session_id: session_id, recent_messages: [], request: request(), metadata: %{}}
  end

  describe "decide/4 with function decider" do
    test "allow" do
      policy = %Policy{decide: fn _, _ -> :allow end}
      assert {:allow, %{}} = Decider.decide(policy, context(), request(), %{})
    end

    test "deny passes reason through" do
      policy = %Policy{decide: fn _, _ -> {:deny, :nope} end}
      assert {{:deny, :nope}, _} = Decider.decide(policy, context(), request(), %{})
    end

    test "context and request are passed to the decider" do
      test_pid = self()

      policy = %Policy{
        decide: fn ctx, req ->
          send(test_pid, {:invoked, ctx, req})
          :allow
        end
      }

      ctx = context("s99")
      req = request("api.example.com")
      Decider.decide(policy, ctx, req, %{})

      assert_receive {:invoked, %Context{session_id: "s99"}, %Request{host: "api.example.com"}}
    end
  end

  describe "decide/4 with MF tuple" do
    defmodule Allower do
      def allow_all(_ctx, _req), do: :allow
      def deny_all(_ctx, _req), do: {:deny, :nope_mf}
    end

    test "calls the named function" do
      policy = %Policy{decide: {Allower, :allow_all}}
      assert {:allow, _} = Decider.decide(policy, context(), request(), %{})

      policy = %Policy{decide: {Allower, :deny_all}}
      assert {{:deny, :nope_mf}, _} = Decider.decide(policy, context(), request(), %{})
    end
  end

  describe "decide/4 with behaviour-backed decider" do
    defmodule BehaviourDecider do
      @behaviour Condukt.Sandbox.Net.Decider

      @impl true
      def decide(_ctx, _req, opts) do
        Keyword.fetch!(opts, :result)
      end
    end

    test "calls module.decide/3 with opts" do
      policy = %Policy{decide: {BehaviourDecider, result: :allow}}
      assert {:allow, _} = Decider.decide(policy, context(), request(), %{})

      policy = %Policy{decide: {BehaviourDecider, result: {:deny, :foo}}}
      assert {{:deny, :foo}, _} = Decider.decide(policy, context(), request(), %{})
    end
  end

  describe "decide/4 timeout" do
    test "denies with :decider_timeout when the decider exceeds the limit" do
      policy = %Policy{
        decide: fn _, _ ->
          Process.sleep(200)
          :allow
        end,
        decide_timeout: 50,
        default: :deny
      }

      assert {{:deny, :default_deny}, _} = Decider.decide(policy, context(), request(), %{})
    end

    test "default :allow on timeout permits" do
      policy = %Policy{
        decide: fn _, _ ->
          Process.sleep(200)
          :allow
        end,
        decide_timeout: 50,
        default: :allow
      }

      assert {:allow, _} = Decider.decide(policy, context(), request(), %{})
    end
  end

  describe "decide/4 cache" do
    test "second call for the same host reuses the cached decision" do
      counter = :counters.new(1, [])

      policy = %Policy{
        decide: fn _, _ ->
          :counters.add(counter, 1, 1)
          :allow
        end,
        decision_cache: true
      }

      {decision, cache} = Decider.decide(policy, context(), request(), %{})
      assert decision == :allow
      assert :counters.get(counter, 1) == 1

      {decision, _cache} = Decider.decide(policy, context(), request(), cache)
      assert decision == :allow
      assert :counters.get(counter, 1) == 1
    end

    test "decision_cache: false invokes the decider every time" do
      counter = :counters.new(1, [])

      policy = %Policy{
        decide: fn _, _ ->
          :counters.add(counter, 1, 1)
          :allow
        end,
        decision_cache: false
      }

      Decider.decide(policy, context(), request(), %{})
      Decider.decide(policy, context(), request(), %{})

      assert :counters.get(counter, 1) == 2
    end
  end

  describe "decide/4 error handling" do
    test "crashing decider applies the default action" do
      policy = %Policy{
        decide: fn _, _ -> raise "boom" end,
        default: :deny
      }

      assert {{:deny, :default_deny}, _} = Decider.decide(policy, context(), request(), %{})
    end

    test "non-decision return applies the default action" do
      policy = %Policy{
        decide: fn _, _ -> :not_a_decision end,
        default: :deny
      }

      assert {{:deny, :default_deny}, _} = Decider.decide(policy, context(), request(), %{})
    end
  end

  describe "decide/4 with no decider" do
    test "returns the default action immediately" do
      policy = %Policy{decide: nil, default: :allow}
      assert {:allow, _} = Decider.decide(policy, context(), request(), %{})

      policy = %Policy{decide: nil, default: :deny}
      assert {{:deny, :default_deny}, _} = Decider.decide(policy, context(), request(), %{})
    end
  end
end

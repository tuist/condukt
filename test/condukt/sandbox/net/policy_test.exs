defmodule Condukt.Sandbox.Net.PolicyTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.Net.Context
  alias Condukt.Sandbox.Net.Policy
  alias Condukt.Sandbox.Net.Request
  alias Condukt.Sandbox.Net.Rule

  defp ctx, do: %Context{}
  defp req(host), do: %Request{host: host, port: 443, started_at: DateTime.utc_now()}

  describe "evaluate/3 with built-in rules" do
    test "AllowHosts short-circuits the pipeline" do
      policy = %Policy{
        rules: [
          {Rule.AllowHosts, hosts: ["api.github.com"]}
        ]
      }

      assert :allow = Policy.evaluate(policy, ctx(), req("api.github.com"))
    end

    test "DenyHosts short-circuits the pipeline" do
      policy = %Policy{
        rules: [
          {Rule.DenyHosts, hosts: ["secret.example.com"]}
        ]
      }

      assert {:deny, :matched_deny_list} = Policy.evaluate(policy, ctx(), req("secret.example.com"))
    end

    test "rules run in the order they were configured" do
      deny_first = %Policy{
        rules: [
          {Rule.DenyHosts, hosts: ["evil.com"]},
          {Rule.AllowHosts, hosts: ["evil.com"]}
        ]
      }

      assert {:deny, :matched_deny_list} = Policy.evaluate(deny_first, ctx(), req("evil.com"))

      allow_first = %Policy{
        rules: [
          {Rule.AllowHosts, hosts: ["evil.com"]},
          {Rule.DenyHosts, hosts: ["evil.com"]}
        ]
      }

      assert :allow = Policy.evaluate(allow_first, ctx(), req("evil.com"))
    end

    test ":default fires when no rule has an opinion" do
      deny_default = %Policy{default: :deny}
      assert {:deny, :default_deny} = Policy.evaluate(deny_default, ctx(), req("anything.com"))

      allow_default = %Policy{default: :allow}
      assert :allow = Policy.evaluate(allow_default, ctx(), req("anything.com"))
    end

    test "AllowHosts and DenyHosts return :continue when their pattern list misses" do
      policy = %Policy{
        rules: [
          {Rule.AllowHosts, hosts: ["api.github.com"]}
        ],
        default: :deny
      }

      assert {:deny, :default_deny} = Policy.evaluate(policy, ctx(), req("api.openai.com"))
    end
  end

  describe "evaluate/3 with Rule.Decide" do
    test "decider :allow flows through" do
      policy = %Policy{
        rules: [
          {Rule.Decide, fun: fn _, _ -> :allow end}
        ]
      }

      assert :allow = Policy.evaluate(policy, ctx(), req("evil.com"))
    end

    test "decider :deny flows through with reason" do
      policy = %Policy{
        rules: [
          {Rule.Decide, fun: fn _, _ -> {:deny, :nope} end}
        ]
      }

      assert {:deny, :nope} = Policy.evaluate(policy, ctx(), req("evil.com"))
    end

    test "AllowHosts before Decide short-circuits the model call" do
      counter = :counters.new(1, [])

      policy = %Policy{
        rules: [
          {Rule.AllowHosts, hosts: ["api.github.com"]},
          {Rule.Decide,
           fun: fn _, _ ->
             :counters.add(counter, 1, 1)
             {:deny, :should_not_run}
           end}
        ]
      }

      assert :allow = Policy.evaluate(policy, ctx(), req("api.github.com"))
      assert :counters.get(counter, 1) == 0
    end
  end

  describe "new/1" do
    test "defaults to an empty rule list and deny default" do
      assert %Policy{rules: [], default: :deny} = Policy.new(nil)
    end

    test "accepts keyword input" do
      policy = Policy.new(rules: [{Rule.AllowHosts, hosts: ["a"]}], default: :allow)
      assert policy.default == :allow
      assert [{Rule.AllowHosts, hosts: ["a"]}] = policy.rules
    end
  end
end

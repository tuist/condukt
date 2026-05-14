defmodule Condukt.Sandbox.Net.PolicyTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.Net.Policy

  describe "matches?/2" do
    test "literal match is case-insensitive" do
      assert Policy.matches?("api.github.com", "api.github.com")
      assert Policy.matches?("API.GITHUB.COM", "api.github.com")
      refute Policy.matches?("github.com", "api.github.com")
    end

    test "single * matches one label only" do
      assert Policy.matches?("api.openai.com", "*.openai.com")
      refute Policy.matches?("v1.api.openai.com", "*.openai.com")
      refute Policy.matches?("openai.com", "*.openai.com")
    end

    test "** matches multiple labels" do
      assert Policy.matches?("v1.api.googleapis.com", "**.googleapis.com")
      assert Policy.matches?("api.googleapis.com", "**.googleapis.com")
      refute Policy.matches?("googleapis.com", "**.googleapis.com")
    end

    test "* inside literal works" do
      assert Policy.matches?("alpha.example.com", "*.example.com")
      assert Policy.matches?("api-eu-west.example.com", "*.example.com")
    end
  end

  describe "evaluate/2" do
    test "deny list takes precedence over allow list" do
      policy = %Policy{allow_hosts: ["*.example.com"], deny_hosts: ["secret.example.com"]}
      assert {:deny, :matched_deny_list} = Policy.evaluate(policy, "secret.example.com")
      assert :allow = Policy.evaluate(policy, "public.example.com")
    end

    test "empty allow list with default :deny rejects everything not in deny list" do
      policy = %Policy{default: :deny}
      assert {:deny, :default_deny} = Policy.evaluate(policy, "anywhere.com")
    end

    test "empty allow list with default :allow permits everything not in deny list" do
      policy = %Policy{default: :allow, deny_hosts: ["bad.example.com"]}
      assert :allow = Policy.evaluate(policy, "good.example.com")
      assert {:deny, :matched_deny_list} = Policy.evaluate(policy, "bad.example.com")
    end

    test "non-matching host with allow list and default :deny returns :no_allow_match" do
      policy = %Policy{allow_hosts: ["*.github.com"]}
      assert {:deny, :no_allow_match} = Policy.evaluate(policy, "evil.com")
    end
  end

  describe "new/1" do
    test "defaults to deny-all" do
      assert %Policy{default: :deny, allow_hosts: [], deny_hosts: []} = Policy.new(nil)
    end

    test "accepts keyword input" do
      policy = Policy.new(allow_hosts: ["api.github.com"], default: :allow)
      assert policy.allow_hosts == ["api.github.com"]
      assert policy.default == :allow
    end

    test "returns existing Policy unchanged" do
      existing = %Policy{allow_hosts: ["x.com"]}
      assert Policy.new(existing) == existing
    end
  end
end

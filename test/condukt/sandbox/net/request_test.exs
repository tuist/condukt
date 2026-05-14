defmodule Condukt.Sandbox.Net.RequestTest do
  use ExUnit.Case, async: true

  alias Condukt.Sandbox.Net.Request

  describe "from_json/1" do
    test "decodes a minimal Tier 1 request" do
      json = %{
        "id" => "req-123",
        "host" => "api.github.com",
        "port" => 443,
        "tier" => "sni",
        "started_at" => "2026-05-14T10:00:00Z"
      }

      assert {:ok, %Request{id: "req-123", tier: :sni, host: "api.github.com", port: 443}} =
               Request.from_json(json)
    end

    test "decodes a Tier 2 request with body fields" do
      json = %{
        "id" => "req-124",
        "host" => "api.github.com",
        "port" => 443,
        "tier" => "body",
        "method" => "POST",
        "path" => "/repos/tuist/condukt/issues",
        "scheme" => "https",
        "request_body_preview" => ~s({"title":"hi"}),
        "request_body_sha256" => "abc",
        "response_status" => 201,
        "bytes_in" => 500,
        "bytes_out" => 100,
        "started_at" => "2026-05-14T10:00:00Z",
        "finished_at" => "2026-05-14T10:00:01Z"
      }

      assert {:ok, request} = Request.from_json(json)
      assert request.tier == :body
      assert request.method == "POST"
      assert request.path == "/repos/tuist/condukt/issues"
      assert request.response_status == 201
      assert request.bytes_in == 500
      assert request.bytes_out == 100
      assert request.finished_at != nil
    end

    test "ignores unknown keys for forward compatibility" do
      json = %{
        "id" => "req-125",
        "host" => "x.com",
        "port" => 443,
        "tier" => "sni",
        "started_at" => "2026-05-14T10:00:00Z",
        "future_field" => "ignored"
      }

      assert {:ok, %Request{}} = Request.from_json(json)
    end

    test "rejects invalid tier" do
      json = %{
        "id" => "x",
        "host" => "x.com",
        "port" => 443,
        "tier" => "bogus",
        "started_at" => "2026-05-14T10:00:00Z"
      }

      assert {:error, {:invalid_tier, "bogus"}} = Request.from_json(json)
    end

    test "rejects missing required fields" do
      assert {:error, _} = Request.from_json(%{"host" => "x.com"})
    end
  end
end

defmodule Mix.Tasks.Condukt.Workspace.PrepareTest do
  use ExUnit.Case, async: true

  @task Mix.Tasks.Condukt.Workspace.Prepare

  describe "dockerfile-output mode" do
    test "writes a Dockerfile and entrypoint shim into the requested directory" do
      out =
        Path.join(
          System.tmp_dir!(),
          "condukt-prepare-test-#{System.unique_integer([:positive])}"
        )

      try do
        # Mix.shell().info goes through ExUnit.CaptureIO in tests; we
        # just rely on the side effect (files on disk).
        Mix.shell(Mix.Shell.Quiet)
        @task.run(["node:20-bookworm", "--output", "ignored:tag", "--dockerfile-output", out])

        assert File.exists?(Path.join(out, "Dockerfile"))
        assert File.exists?(Path.join(out, "condukt-net-entrypoint.sh"))

        dockerfile = File.read!(Path.join(out, "Dockerfile"))
        assert dockerfile =~ "FROM node:20-bookworm"
        assert dockerfile =~ "NODE_EXTRA_CA_CERTS=/etc/condukt/ca.pem"
        assert dockerfile =~ "REQUESTS_CA_BUNDLE=/etc/condukt/ca.pem"
        assert dockerfile =~ "CURL_CA_BUNDLE=/etc/condukt/ca.pem"
        assert dockerfile =~ "GIT_SSL_CAINFO=/etc/condukt/ca.pem"
        assert dockerfile =~ "ENTRYPOINT [\"/usr/local/bin/condukt-net-entrypoint\"]"

        shim = File.read!(Path.join(out, "condukt-net-entrypoint.sh"))
        assert shim =~ "update-ca-certificates"
        assert shim =~ "update-ca-trust"
        assert shim =~ "/etc/condukt/ca.pem"
        assert shim =~ "exec \"$@\""
      after
        File.rm_rf!(out)
        Mix.shell(Mix.Shell.IO)
      end
    end

    test "embeds preserve-entrypoint when provided" do
      out =
        Path.join(
          System.tmp_dir!(),
          "condukt-prepare-test-#{System.unique_integer([:positive])}"
        )

      try do
        Mix.shell(Mix.Shell.Quiet)

        @task.run([
          "node:20",
          "--output",
          "x:y",
          "--dockerfile-output",
          out,
          "--preserve-entrypoint",
          "/usr/bin/tini --"
        ])

        dockerfile = File.read!(Path.join(out, "Dockerfile"))
        assert dockerfile =~ ~s(CONDUKT_NET_PRESERVED_ENTRYPOINT="/usr/bin/tini --")
      after
        File.rm_rf!(out)
        Mix.shell(Mix.Shell.IO)
      end
    end
  end

  describe "argument validation" do
    test "raises when input image is missing" do
      assert_raise Mix.Error, ~r/expected: mix condukt/, fn ->
        @task.run(["--output", "x:y"])
      end
    end

    test "raises when --output is missing" do
      assert_raise KeyError, fn ->
        @task.run(["node:20"])
      end
    end

    test "raises on unknown switches" do
      assert_raise Mix.Error, ~r/unknown options/, fn ->
        @task.run(["node:20", "--output", "x:y", "--bogus"])
      end
    end
  end
end

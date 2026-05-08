defmodule Condukt.Workflows.NIF do
  @moduledoc false
  # Low-level NIF binding for the workflows subsystem. This module is
  # internal: callers should use `Condukt.Workflows`.

  if System.get_env("CONDUKT_WORKFLOWS_DISABLE") in ["1", "true"] do
    @disabled_error {:error, :nif_disabled}

    def compile(_source, _filename), do: @disabled_error
    def parse_only(_source, _filename), do: @disabled_error
  else
    use RustlerPrecompiled,
      otp_app: :condukt,
      crate: "condukt_workflows",
      base_url: "https://github.com/tuist/condukt/releases/download/#{Mix.Project.config()[:version]}",
      force_build:
        System.get_env("CONDUKT_WORKFLOWS_PRECOMPILED") not in ["1", "true"] and
          Mix.env() in [:dev, :test],
      version: Mix.Project.config()[:version],
      targets: ~w(
        aarch64-apple-darwin
        aarch64-unknown-linux-gnu
        x86_64-apple-darwin
        x86_64-pc-windows-msvc
        x86_64-unknown-linux-gnu
      ),
      nif_versions: ~w(2.16 2.17)

    def compile(_source, _filename), do: err()
    def parse_only(_source, _filename), do: err()

    defp err, do: :erlang.nif_error(:nif_not_loaded)
  end
end

defmodule Condukt.Microsandbox.NIF do
  @moduledoc false

  @disable_env System.get_env("CONDUKT_MICROSANDBOX_DISABLE") in ["1", "true"]

  if @disable_env or
       not (
         arch = :erlang.system_info(:system_architecture) |> List.to_string()

         case :os.type() do
           {:unix, :darwin} -> String.starts_with?(arch, "aarch64")
           {:unix, :linux} -> String.starts_with?(arch, "aarch64") or String.starts_with?(arch, "x86_64")
           _ -> false
         end
       ) do
    @disabled_error if(@disable_env, do: {:error, :nif_disabled}, else: {:error, :unsupported_target})

    def new_session(_config), do: @disabled_error
    def shutdown(_session), do: :ok
    def exec(_session, _shell, _command, _cwd, _env, _timeout_ms), do: @disabled_error
    def read_file(_session, _path), do: @disabled_error
    def write_file(_session, _path, _content), do: @disabled_error
  else
    use RustlerPrecompiled,
      otp_app: :condukt,
      crate: "condukt_microsandbox",
      base_url: "https://github.com/tuist/condukt/releases/download/#{Mix.Project.config()[:version]}",
      force_build:
        Mix.env() in [:dev, :test] or
          System.get_env("CONDUKT_MICROSANDBOX_BUILD") in ["1", "true"],
      version: Mix.Project.config()[:version],
      targets: ~w(
        aarch64-apple-darwin
        aarch64-unknown-linux-gnu
        x86_64-unknown-linux-gnu
      ),
      nif_versions: ~w(2.16 2.17)

    def new_session(_config), do: err()
    def shutdown(_session), do: err()
    def exec(_session, _shell, _command, _cwd, _env, _timeout_ms), do: err()
    def read_file(_session, _path), do: err()
    def write_file(_session, _path, _content), do: err()

    defp err, do: :erlang.nif_error(:nif_not_loaded)
  end
end

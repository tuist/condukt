# Installation

Condukt can run as a Hex library inside an Elixir application or as the
standalone `condukt` engine for workflow files.

## Library mode

Add `:condukt` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:condukt, "~> 0.13"}
  ]
end
```

Then fetch dependencies:

```sh
mix deps.get
```

Use library mode when Condukt should live inside your own OTP supervision tree.

## Engine mode

Install the standalone executable from GitHub Releases with mise:

```sh
mise use -g github:tuist/condukt
condukt version
```

Use engine mode when you want to run a workflow file directly:

```sh
condukt check hello.exs
condukt run hello.exs --input '{"name":"world"}'
condukt compile hello.exs > hello.json
```

The release assets include Linux x64, macOS x64, macOS arm64, and Windows x64
builds.

See [Workflows](workflows.md) for creating, running, and sharing workflow
files.

defmodule Condukt.MixProject do
  use Mix.Project

  @version "1.13.1"
  @source_url "https://github.com/tuist/condukt"

  def project do
    [
      app: :condukt,
      version: @version,
      # 1.18 is the floor because the library uses the built-in `JSON` module,
      # which shipped in that release. Declaring 1.17 promised a version the
      # code cannot compile on.
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "Condukt",
      description: "A framework for building AI agents in Elixir",
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r/test\/support\//],
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {Condukt.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # LLM client (supports Anthropic, OpenAI, Google, and 15+ more providers)
      {:req_llm, "~> 1.21"},

      # ReqLLM's Amazon Bedrock provider uses this to sign requests. ReqLLM
      # 1.21 makes it optional, but it was available to Condukt users before
      # this upgrade and remains part of the supported provider surface.
      {:ex_aws_auth, "~> 1.4"},

      # JSON Schema validation for operation input/output
      {:jsv, "~> 0.16"},

      # Command execution with child process shutdown propagation
      {:muontrap, "~> 1.7"},
      {:plug, "~> 1.16", optional: true},

      # Fan-out for `Condukt.Notifiers.PubSub`. Optional: a project that
      # delivers session events some other way should not carry it.
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:bandit, "~> 1.5", optional: true},

      # Telemetry
      {:telemetry, "~> 1.0"},

      # UUIDv7 generation for session identifiers in telemetry metadata
      {:uniq, "~> 0.6"},

      # Native interop with the bashkit virtual sandbox.
      # Dev builds compile NIFs from source by default. Tests can opt into
      # source builds with the *_BUILD flags, while non-dev consumers download
      # prebuilt artifacts via `rustler_precompiled`.
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, ">= 0.0.0", only: [:dev, :test], runtime: false},

      # Kubernetes sandbox client. Only loaded when an application uses
      # `Condukt.Sandbox.Kubernetes` at runtime, so projects that don't run
      # on K8s don't pay for the HTTP stack at boot.
      {:k8s, "~> 2.8"},

      # Per-session ephemeral CA generation for the network policy egress
      # MITM path. Pure Elixir, no native deps.
      {:x509, "~> 0.9"},

      # Development & Testing
      {:quokka, "~> 2.12", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.0", only: :test}
    ]
  end

  defp docs do
    [
      main: "overview",
      extras: [
        "web/priv/docs/framework/elixir/index.md": [title: "Overview", filename: "overview"],
        "web/priv/docs/framework/elixir/installation.md": [title: "Installation"],
        "web/priv/docs/framework/elixir/getting-started.md": [title: "Getting Started"],
        "web/priv/docs/framework/elixir/agents.md": [title: "Agents"],
        "web/priv/docs/framework/elixir/one-shot-runs.md": [title: "One-Shot Runs"],
        "web/priv/docs/framework/elixir/tools.md": [title: "Tools"],
        "web/priv/docs/framework/elixir/subagents.md": [title: "Sub-agents"],
        "web/priv/docs/framework/elixir/mcp.md": [title: "MCP"],
        "web/priv/docs/framework/elixir/http-routes.md": [title: "HTTP Routes"],
        "web/priv/docs/framework/elixir/sandbox.md": [title: "Sandbox"],
        "web/priv/docs/framework/elixir/network-policy.md": [title: "Network Policy"],
        "web/priv/docs/framework/elixir/streaming-and-events.md": [title: "Streaming and Events"],
        "web/priv/docs/framework/elixir/sessions-and-persistence.md": [title: "Sessions and Persistence"],
        "web/priv/docs/framework/elixir/compaction.md": [title: "Compaction"],
        "web/priv/docs/framework/elixir/redaction.md": [title: "Redaction"],
        "web/priv/docs/framework/elixir/secrets.md": [title: "Secrets"],
        "web/priv/docs/framework/elixir/project-instructions.md": [title: "Project Instructions"],
        "web/priv/docs/framework/elixir/telemetry.md": [title: "Telemetry"],
        "web/priv/docs/framework/elixir/providers.md": [title: "Providers"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_extras: [
        Introduction: [
          "web/priv/docs/framework/elixir/index.md",
          "web/priv/docs/framework/elixir/installation.md",
          "web/priv/docs/framework/elixir/getting-started.md"
        ],
        Agents: [
          "web/priv/docs/framework/elixir/agents.md",
          "web/priv/docs/framework/elixir/one-shot-runs.md",
          "web/priv/docs/framework/elixir/tools.md",
          "web/priv/docs/framework/elixir/subagents.md"
        ],
        Integrations: [
          "web/priv/docs/framework/elixir/mcp.md",
          "web/priv/docs/framework/elixir/http-routes.md"
        ],
        Guides: [
          "web/priv/docs/framework/elixir/sandbox.md",
          "web/priv/docs/framework/elixir/network-policy.md",
          "web/priv/docs/framework/elixir/streaming-and-events.md",
          "web/priv/docs/framework/elixir/sessions-and-persistence.md",
          "web/priv/docs/framework/elixir/compaction.md",
          "web/priv/docs/framework/elixir/redaction.md",
          "web/priv/docs/framework/elixir/secrets.md",
          "web/priv/docs/framework/elixir/project-instructions.md",
          "web/priv/docs/framework/elixir/telemetry.md",
          "web/priv/docs/framework/elixir/providers.md"
        ],
        Reference: [
          "CHANGELOG.md"
        ]
      ],
      source_ref: @version,
      source_url: @source_url,
      groups_for_modules: [
        Core: [
          Condukt,
          Condukt.Session,
          Condukt.Operation,
          Condukt.Plug,
          Condukt.Message,
          Condukt.Telemetry,
          Condukt.TraceContext
        ],
        "Project Context": [
          Condukt.Context,
          Condukt.Context.Skill
        ],
        Tools: [
          Condukt.Tool,
          Condukt.Tool.Inline,
          Condukt.Tools,
          Condukt.Tools.Read,
          Condukt.Tools.Bash,
          Condukt.Tools.Command,
          Condukt.Tools.Edit,
          Condukt.Tools.Write,
          Condukt.Tools.Glob,
          Condukt.Tools.Grep,
          Condukt.Tools.Subagent
        ],
        MCP: [
          Condukt.MCP,
          Condukt.MCP.Server,
          Condukt.MCP.Client,
          Condukt.MCP.Registry
        ],
        Sandbox: [
          Condukt.Sandbox,
          Condukt.Sandbox.Local,
          Condukt.Sandbox.Virtual,
          Condukt.Sandbox.Microsandbox,
          Condukt.Sandbox.Virtual.Tools.Mount,
          Condukt.Sandbox.Kubernetes,
          Condukt.Sandbox.NetworkPolicy,
          Condukt.Sandbox.NetworkPolicy.Request,
          Condukt.Sandbox.NetworkPolicy.Event,
          Condukt.Sandbox.NetworkPolicy.Context,
          Condukt.Sandbox.NetworkPolicy.Decider,
          Condukt.Sandbox.NetworkPolicy.AgentDecider,
          Condukt.Sandbox.NetworkPolicy.CA
        ],
        "Session Stores": [
          Condukt.SessionStore,
          Condukt.SessionStore.Snapshot,
          Condukt.SessionStore.Memory,
          Condukt.SessionStore.Disk
        ],
        Compaction: [
          Condukt.Compactor,
          Condukt.Compactor.Sliding,
          Condukt.Compactor.ToolResultPrune
        ],
        Redaction: [
          Condukt.Redactor,
          Condukt.Redactors.Regex,
          Condukt.Redactors.Secrets
        ],
        Secrets: [
          Condukt.SecretProvider,
          Condukt.Secrets,
          Condukt.Secrets.Providers.Env,
          Condukt.Secrets.Providers.OnePassword,
          Condukt.Secrets.Providers.Static
        ],
        Providers: [
          Condukt.Providers.Ollama
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files:
        ~w(lib web/priv/docs/framework/elixir priv/ca-certificates native/condukt_bashkit/Cargo.toml native/condukt_bashkit/Cargo.lock native/condukt_bashkit/src native/condukt_bashkit/.cargo native/condukt_bashkit/rust-toolchain.toml native/condukt_bashkit/README.md native/condukt_microsandbox/Cargo.toml native/condukt_microsandbox/Cargo.lock native/condukt_microsandbox/src native/condukt_microsandbox/rust-toolchain.toml native/condukt_microsandbox/README.md checksum-Elixir.Condukt.Bashkit.NIF.exs checksum-Elixir.Condukt.Microsandbox.NIF.exs .formatter.exs mix.exs README.md CHANGELOG.md LICENSE MIT.md)
    ]
  end

  defp aliases do
    [
      lint: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end

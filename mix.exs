defmodule Condukt.MixProject do
  use Mix.Project

  @version "0.20.0"
  @source_url "https://github.com/tuist/condukt"

  def project do
    [
      app: :condukt,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "Condukt",
      description: "A framework for building AI agents in Elixir",
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r/test\/support\//],
      aliases: aliases(),
      releases: releases()
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
      {:req_llm, "~> 1.6"},

      # JSON Schema validation for operation input/output
      {:jsv, "~> 0.16"},

      # Command execution with child process shutdown propagation
      {:muontrap, "~> 1.7"},

      # Workflows manifests, lockfiles, triggers, and optional HTTP serving
      {:toml, "~> 0.7.0"},
      {:crontab, "~> 1.1"},
      {:plug, "~> 1.16", optional: true},
      {:bandit, "~> 1.5", optional: true},

      # Standalone engine releases for users who want the workflow runner
      # without installing Erlang, Elixir, or Mix.
      {:burrito, "~> 1.5", optional: true},

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
        "guides/overview.md": [title: "Overview"],
        "guides/installation.md": [title: "Installation"],
        "guides/getting_started.md": [title: "Getting Started"],
        "guides/agents.md": [title: "Agents"],
        "guides/anonymous_workflows.md": [title: "Anonymous Workflows"],
        "guides/tools.md": [title: "Tools"],
        "guides/subagents.md": [title: "Sub-agents"],
        "guides/workflows.md": [title: "Workflows"],
        "guides/workflow_starlark_api.md": [title: "Workflow Starlark API"],
        "guides/sandbox.md": [title: "Sandbox"],
        "guides/streaming_and_events.md": [title: "Streaming and Events"],
        "guides/sessions_and_persistence.md": [title: "Sessions and Persistence"],
        "guides/compaction.md": [title: "Compaction"],
        "guides/redaction.md": [title: "Redaction"],
        "guides/secrets.md": [title: "Secrets"],
        "guides/project_instructions.md": [title: "Project Instructions"],
        "guides/telemetry.md": [title: "Telemetry"],
        "guides/providers.md": [title: "Providers"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_extras: [
        Introduction: [
          "guides/overview.md",
          "guides/installation.md",
          "guides/getting_started.md"
        ],
        Agents: [
          "guides/agents.md",
          "guides/anonymous_workflows.md",
          "guides/tools.md",
          "guides/subagents.md"
        ],
        Workflows: [
          "guides/workflows.md",
          "guides/workflow_starlark_api.md"
        ],
        Guides: [
          "guides/sandbox.md",
          "guides/streaming_and_events.md",
          "guides/sessions_and_persistence.md",
          "guides/compaction.md",
          "guides/redaction.md",
          "guides/secrets.md",
          "guides/project_instructions.md",
          "guides/telemetry.md",
          "guides/providers.md"
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
          Condukt.Message,
          Condukt.Telemetry
        ],
        "Project Context": [
          Condukt.Context,
          Condukt.Context.Skill
        ],
        Engine: [
          Condukt.Engine.CLI
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
        Workflows: [
          Condukt.Workflows,
          Condukt.Workflows.AgentShim,
          Condukt.Workflows.Project,
          Condukt.Workflows.Workflow,
          Condukt.Workflows.Manifest,
          Condukt.Workflows.Lockfile,
          Condukt.Workflows.Store,
          Condukt.Workflows.Resolver,
          Condukt.Workflows.Resolver.Requirement,
          Condukt.Workflows.Fetcher,
          Condukt.Workflows.Fetcher.Git,
          Condukt.Workflows.Eval,
          Condukt.Workflows.Error,
          Condukt.Workflows.ToolRegistry,
          Condukt.Workflows.Runtime,
          Condukt.Workflows.Runtime.Worker,
          Condukt.Workflows.Runtime.Cron,
          Condukt.Workflows.Runtime.WebhookListener,
          Condukt.Workflows.Runtime.WebhookRouter
        ],
        Sandbox: [
          Condukt.Sandbox,
          Condukt.Sandbox.Local,
          Condukt.Sandbox.Virtual,
          Condukt.Sandbox.Virtual.Tools.Mount
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
        ~w(lib guides native/condukt_bashkit/Cargo.toml native/condukt_bashkit/Cargo.lock native/condukt_bashkit/src native/condukt_bashkit/.cargo native/condukt_bashkit/rust-toolchain.toml native/condukt_bashkit/README.md checksum-Elixir.Condukt.Bashkit.NIF.exs native/condukt_workflows/Cargo.toml native/condukt_workflows/Cargo.lock native/condukt_workflows/src native/condukt_workflows/rust-toolchain.toml native/condukt_workflows/README.md checksum-Elixir.Condukt.Workflows.NIF.exs .formatter.exs mix.exs README.md CHANGELOG.md LICENSE MIT.md)
    ]
  end

  defp aliases do
    [
      lint: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end

  defp releases do
    [
      condukt: [
        steps: [:assemble, &Burrito.wrap/1],
        applications: [condukt: :permanent],
        burrito: [
          targets: [
            linux_x64: [os: :linux, cpu: :x86_64],
            macos_x64: [os: :darwin, cpu: :x86_64, skip_nifs: true],
            macos_arm64: [os: :darwin, cpu: :aarch64, skip_nifs: true],
            windows_x64: [os: :windows, cpu: :x86_64, skip_nifs: true]
          ]
        ]
      ]
    ]
  end
end

# AGENTS.md

## Command Execution

- For running bash commands from Elixir, use `MuonTrap` instead of `System`.
- Prefer `MuonTrap` because it propagates process shutdowns to child processes.
- Reference: https://hexdocs.pm/muontrap/readme.html

## Sandboxes

- Tools that read/write files or run subprocesses must route through the
  `Condukt.Sandbox.*` facade, not `File.*` / `MuonTrap.cmd/3` directly. The
  sandbox is in `context.sandbox` when the tool's `call/2` is invoked.
- Session secrets are resolved through `Condukt.Secrets` and exposed to tools
  through `context.secrets`; command tools should use `Condukt.Secrets.env/1`
  or `Condukt.Secrets.merge_env/2` instead of reading provider-specific secret
  stores directly.
- `Condukt.Sandbox.Local` is the default and operates against the host
  filesystem. `Condukt.Sandbox.Virtual` is in-tree and routes through a
  Rust NIF wrapping bashkit for in-memory virtual filesystem isolation.
  `Condukt.Sandbox.Kubernetes` runs each session in a dedicated pod via
  the `:k8s` library; idempotent on a stable `:id` so an Oban-style
  worker can reattach the same pod across job retries. K8s sandboxes
  refresh a heartbeat annotation for stale-pod reaping, support
  `reap_stale/1`, stream writes through exec stdin, and can clone an
  init-time `:workspace_source` git repository when the image includes
  `git`.
- `Condukt.Tools.Command` is the explicit exception: it runs a host-allowlisted
  executable directly, by design, and is not sandbox-routed.
- See `guides/sandbox.md` for behaviour shape and how to add custom sandboxes.

## Network Policy

- `Condukt.Sandbox.NetworkPolicy` is the per-session egress audit +
  policy layer. Set it via `network_policy:` on the
  `Condukt.Sandbox.Kubernetes` spec; other sandboxes ignore the
  option (no enforcement plane).
- `rules` is a keyword list walked top to bottom: `allow:`/`deny:`
  host globs and `decide:` callable (2-arity fun, `{mod, fun}`, a
  module, or `{mod, opts}`). Decide tuning is scoped to the rule:
  `decide: [call: callable, timeout:, cache:, context_messages:,
  context_metadata:]`. The struct itself only carries `:rules`,
  `:default`, `:redact`, `:max_body_capture`.
  `...NetworkPolicy.AgentDecider` wraps a `Condukt` agent and injects
  the decision contract as the agent's `:output` schema; do not
  describe the wire format in the agent prompt.
- A `:decide` rule needs the BEAM<->sidecar control channel: a
  `pods/portforward` WebSocket (`...K8s.PortForward` ->
  `...K8s.ControlBridge`, supervised, re-dials with backoff). This
  requires a cluster serving WebSocket port-forward (Kubernetes >=
  1.30, KEP-4006) and the `pods/portforward` RBAC verb;
  `allow`/`deny`-only policies do not. There is no `condukt-egress`
  control-bridge subcommand: the BEAM reaches the control port
  directly.
- The Rust sidecar lives under `native/condukt_egress/` (one binary,
  `netfilter-setup` + `proxy` subcommands; toolchain pinned in its
  `rust-toolchain.toml`; image `ghcr.io/tuist/condukt-egress:<version>`
  built by `.github/workflows/release.yml`, overridable per-spec via
  `:network_policy_image`). Its Dockerfile build is verified on every
  PR by `.github/workflows/condukt-egress.yml`. Workspace MITM trust
  is injected by the pod spec with no image preparation (Java
  keystores excepted).
- See `guides/network_policy.md` for topology, the policy/decider
  model, context shape, telemetry, trust-injection details, and
  limitations. Keep deep architecture there, not here.

## MCP

- Condukt connects to external Model Context Protocol servers as a
  client, exposing each server's tools to agents and workflows under
  `<server>.<tool>` ids. See `guides/mcp.md` for transports, auth
  shapes, and HCL syntax.
- Three transports are supported: `stdio` (subprocess + newline JSON-RPC),
  `http_sse` (legacy 2024-11 HTTP+SSE), and `streamable_http` (2025-03-26).
  No MCP server mode in v1.
- Stdio MCP subprocesses are NOT routed through `Condukt.Sandbox` for
  the same reason `Condukt.Tools.Command` is exempt: the binary is
  selected by the operator, not by the model. `Condukt.MCP.Transport.Stdio`
  uses `Port.open` directly with bidirectional binary streaming.
- Bearer auth values are not auto-registered as session secrets. If a
  caller wants the value redacted from transcripts, declare it under
  `:secrets` as well.
- Interactive OAuth is intentionally out of scope. The library accepts
  bearer tokens or `client_credentials` grants resolved through
  `Condukt.Secrets`-shaped refs.

## HTTP routes

- Module-defined one-shot agents and statically declared `operation/2`
  entrypoints can be exposed as JSON POST endpoints with `Condukt.Plug` or
  `Condukt.Plug`.
- Plug routers mount `Condukt.Plug` directly with `to: Condukt.Plug` and
  `init_opts:`. Pass `agent:` for normal one-shot agents and add `operation:`
  for typed operation routes.
- Agent route requests may use a raw prompt body, a JSON string body, or a JSON
  object with an optional `"prompt"` string. If omitted, the route's `:prompt`
  option is used, then an empty prompt.
- Operation route requests must be JSON objects matching the operation input
  schema. Responses are JSON envelopes shaped as
  `%{ok: true, result: result}` or
  `%{ok: false, error: %{code: code, message: message}}`.

## Sub-agents

- Agents can declare `subagents/0` as `role: AgentModule` or
  `role: {AgentModule, opts}`. They can also use `role: [opts]` to create an
  anonymous child agent backed by `Condukt.AnonymousAgent`. Sessions
  auto-inject `Condukt.Tools.Subagent` when roles are registered.
- Role opts can declare optional `:input`/`:input_schema` and
  `:output`/`:output_schema` JSON Schemas. Only fields listed in `required`
  are required.
- Child sessions inherit the parent `:sandbox`, `:cwd`, `:api_key`,
  `:base_url`, and resolved `:secrets` unless those values are overridden in
  the role registration opts.
- See `guides/subagents.md` for declaration, inheritance, and supervision
  details.

## Agent runtimes

- Agents can be declared with `use Condukt.Agent, runtime: RuntimeModule` or
  `runtime: {RuntimeModule, opts}`. The default runtime is
  `Condukt.AgentRuntimes.Native`, where `Condukt.Session` drives the ReqLLM
  turn and tool loop.
- Non-native runtime modules implement `Condukt.AgentRuntime.run/3`. Condukt
  still owns session identity, sandbox setup, secret resolution, project
  instructions, telemetry, workflow placement, and sub-agent boundaries.
- Built-in SDK runtime adapters are `Condukt.AgentRuntimes.Codex`, which shells
  out to `codex exec`, and `Condukt.AgentRuntimes.Claude`, which shells out to
  `claude --print`. Both use `MuonTrap`, the session cwd, and resolved session
  secrets.
- Treat `model/0`, `thinking_level/0`, `tools/0`, `mcp_servers/0`, and
  native tool-loop callbacks as native-only unless a runtime adapter documents
  an explicit mapping. Use `system_prompt/0` for durable guidance to
  runtime-backed agents; Condukt passes the composed prompt to the runtime.
- See `guides/agents.md` for runtime boundary and callback implications.

## Native NIF (`native/condukt_bashkit/`)

- The `condukt_bashkit` Rust crate wraps the bashkit virtual sandbox into
  a NIF. Build it with `cd native/condukt_bashkit && cargo build --release`
  or via `MIX_ENV=dev mix compile`.
- Toolchain: Rust 1.94.x, pinned in `native/condukt_bashkit/rust-toolchain.toml`
  (also in `mise.toml`).
- `mix compile` source-builds the NIF in `MIX_ENV=dev`. Other Mix
  environments download the precompiled NIF from the GitHub release.
- The release publish job runs with `MIX_ENV=prod` so Hex package validation
  and publishing exercise the precompiled NIF path.
- Releases must publish precompiled artifacts for every target listed in
  `lib/condukt/bashkit/nif.ex`'s `:targets` option, plus a checksum file
  named `checksum-Elixir.Condukt.Bashkit.NIF.exs` in the package source.
  See `.github/workflows/release.yml` for the build matrix.

## Workflows

- A workflow is a typed DAG of steps authored in HCL and normalized to the
  canonical workflow document internally. That document is what the engine
  executes, what `condukt check` validates, and what editors and agents can
  read and write. There is no project layout, manifest, or lockfile. HCL
  workflows use the `workflow "name"` label as the run name. `.exs`
  workflow maps may set `name`; if they omit it, Condukt falls back to the
  file basename.
- Workflows are validated by `Condukt.Workflows.Validator`. Top level:
  `name`, `inputs`, optional `runtime`, `steps`, `output`.
  `runtime` carries workflow-level defaults such as `model`, `sandbox`
  (`local`/`virtual`), and `cwd`; library options passed to
  `Condukt.Workflows.run/3` override those defaults. Each step has a `kind`
  (`cmd`/`agent`/`http`/`tool`/`map`), optional `needs`, optional `when`,
  and kind-specific fields. Agent steps may omit `model` when a workflow or
  caller model is configured. HCL requires every `task.X` reference inside
  a step to be declared in that step's `needs` list so the DAG is visible
  in the authored file.
- The expression sub-language is intentionally small: `${...}`
  interpolation with member access, indexing, comparisons, boolean ops,
  literals, unary minus, and `:json`/`:csv` formatters. No arbitrary
  function calls or arithmetic beyond comparisons. Anything more
  substantial belongs in a `cmd`/`agent`/`tool` step. Member access on
  `null` returns `null` so a reference to a skipped step degrades
  gracefully; missing keys against a real value still error.
- The authored workflow format is `.hcl`. Use `workflow "name" { ... }`
  with `input`, `cmd`, `http`, `agent`, `tool`, and `map` blocks. HCL
  references use `input.name` and `task.step.output`; the compiler rewrites
  them to canonical `${inputs.name}` and `${steps.step.output}` strings.
  Direct map-returning `.exs` files remain supported only for lower-level
  generation. Atom keys and atom values are normalized to strings by
  `Condukt.Workflows.Compiler` before document validation.
- `Condukt.Workflows.HCLCompiler.compile/1` reads, parses with `hxl`, and
  normalizes an `.hcl` file. `Condukt.Workflows.Compiler.compile/1` reads,
  evaluates, and normalizes an `.exs` file. Validation and execution are
  pure Elixir; there is no native NIF for workflows.
- `Condukt.Workflows.run/3` accepts either an HCL source string or a loaded
  `Condukt.Workflows.Document`. A binary passed to `run/3` is HCL content,
  not a file path. HCL file callers should `File.read!/1` first and pass
  the content to `run/3`. `Condukt.Workflows.load/1` is for callers that
  explicitly need a reusable `Condukt.Workflows.Document` or need to load a
  `.exs` workflow generator file. `run/3` accepts optional `:path` metadata
  for HCL string diagnostics.
- `Condukt.Workflows.Executor` is the dispatch point for step kinds on
  the Elixir side. Add new kinds there and in the validator together.
- CLI verbs are `condukt run PATH [--input JSON]` and
  `condukt check PATH`, mirrored by `mix condukt.run` and
  `mix condukt.check`. `run` and `check` accept `.hcl` and `.exs`
  paths; both are loaded and normalized internally. JSON and YAML are not
  supported workflow file formats.
- Tool ids on `tool` steps are resolved through
  `Condukt.Workflows.ToolRegistry`. Built-ins
  (`Read`/`Write`/`Edit`/`Glob`/`Grep`/`Bash`) are registered out of
  the box; callers extend the registry by passing
  `tools: %{id => spec}` as an option to `Condukt.Workflows.run/3`.
- Future slices will add: remote `load(...)` of versioned helpers from
  GitHub URLs (with normalized documents cached locally), an opt-in `--lock`
  integrity file, triggers (`condukt.trigger.webhook`,
  `condukt.schedule.cron`) declared at the top of the workflow document,
  and a visual editor that reads and writes the same document shape.

## Engine releases

- Condukt has two distribution modes. Library mode is the Hex package consumed
  by Elixir applications. Engine mode is the standalone `condukt` executable
  built with Burrito for running workflow files without a local Elixir or
  Erlang install.
- Burrito targets are configured in `mix.exs` under `releases/0`. Release CI
  builds Linux x64, macOS x64, macOS arm64, and Windows x64 archives and
  attaches them to the GitHub release after the Hex package and NIF artifacts
  are published.
- Engine assets are named for mise's GitHub backend autodetection:
  `condukt-<version>-linux-x64-gnu.tar.gz`,
  `condukt-<version>-macos-x64.tar.gz`,
  `condukt-<version>-macos-arm64.tar.gz`, and
  `condukt-<version>-windows-x64-msvc.zip`.
- Burrito requires Zig, XZ, and 7z at build time. Zig is pinned in `mise.toml`.
  Erlang is pinned to an exact OTP 28 patch version so Burrito can fetch the
  matching precompiled ERTS from the Beam Machine cache.
- Engine builds set `CONDUKT_BASHKIT_PRECOMPILED=1` so the release
  bytecode points at the target-specific NIF artifacts already
  attached to the GitHub release.

## Workflow

- After every change, create a git commit and push it to the current branch.

## Elixir

- Condukt supports module-defined one-shot runs with
  `Condukt.run(MyApp.Agent, prompt, opts)`. Prefer this form for synchronous
  work that does not need conversation history. Use `start_link/1` and a
  persistent session only when the caller needs state, streaming, persistence,
  supervision, or multiple turns against the same process.
- Do not type Elixir code by hand when avoidable. Prefer structural edits and tool-assisted changes.
- Do not introduce `try`/`catch` or `rescue` patterns in production Elixir
  code. Prefer tuple-returning APIs and explicit pattern matching. If a
  boundary genuinely needs non-local failure handling, use an existing project
  abstraction or add one deliberately instead of catching locally.
- Tests must not mutate global process state such as `System.put_env/2`,
  `System.delete_env/1`, `Application.put_env/3`, or
  `Application.delete_env/2`. Prefer explicit dependency injection, per-test
  processes, unique temporary paths, and local options so affected tests can run
  with `async: true`.

## Marketing site (`website/`)

The marketing site lives under `website/` and is built with [Eleventy](https://www.11ty.dev/).

- Source: `website/src/` (templates use Nunjucks, layouts in `website/src/_includes/layouts/`).
- Package manager: [aube](https://github.com/endevco/aube), pinned in `mise.toml`. Use `aube ci`, `aube install`, `aube add <pkg>`, `aube run <script>` (or `aubr <script>`). Do not invoke `npm`/`pnpm`/`yarn` directly.
- Build: `cd website && aube ci && aube run build` — outputs to `website/_site`.
- Local preview: `cd website && aube run dev`.
- Deployment: pushes to `main` that touch `website/**` deploy to the Cloudflare Pages project `condukt-website` via `.github/workflows/website.yml`. The job uses `cloudflare/wrangler-action` (`wrangler pages deploy`) and reads `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from repo secrets. The custom domain `condukt.tuist.dev` is bound to that Pages project in the Cloudflare dashboard.
- Pages config: `website/wrangler.toml` declares the project name and `pages_build_output_dir`.
- Toolchain: Node and aube are pinned in `mise.toml`; bump there rather than ad-hoc.

## Documentation (`guides/`)

Per-feature ExDoc pages live under `guides/` and are wired into `mix.exs` via `extras` and `groups_for_extras`. They are published to HexDocs alongside the API reference.

- When adding, removing, or meaningfully changing a feature (tools, sessions, compaction, redaction, providers, telemetry, project instructions, streaming, etc.), update the corresponding page under `guides/` in the same change.
- When introducing a new top-level feature, add a new guide page and register it in both `extras` and `groups_for_extras` in `mix.exs`.
- Avoid em dashes in guide prose (use colons, commas, or periods).
- Verify with `mix docs` before committing.

## Keeping this file up to date

- Whenever a change adds, removes, or meaningfully alters an agent capability, workflow, deployment target, or required tool, update this file in the same change. The agent reads `AGENTS.md` at startup and stale entries cause it to act on outdated assumptions.

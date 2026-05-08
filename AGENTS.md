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
- `Condukt.Tools.Command` is the explicit exception: it runs a host-allowlisted
  executable directly, by design, and is not sandbox-routed.
- See `guides/sandbox.md` for behaviour shape and how to add custom sandboxes.

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

- A workflow is a typed JSON document describing a DAG of steps. The
  document is the source of truth: it is what the engine executes, what
  `condukt check` validates, and what editors and agents read and write.
  YAML is accepted on input as a JSON superset and converted at load time.
  There is no project layout, manifest, or lockfile; the basename of the
  file is the run name.
- The schema lives at `priv/schemas/condukt.workflow.schema.json` and
  is referenced from workflow files via its raw GitHub URL,
  `https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json`.
  Top level: `name`, `inputs`, `steps`, `output`. Each step has a `kind`
  (`cmd`/`agent`/`http`/`tool`/`map`), optional `needs`, optional
  `when`, and kind-specific fields. Implicit dependencies are inferred
  from `${steps.X.*}` references.
- The expression sub-language is intentionally small: `${...}`
  interpolation with member access, indexing, comparisons, boolean ops,
  literals, unary minus, and `:json`/`:csv` formatters. No arbitrary
  function calls or arithmetic beyond comparisons. Anything more
  substantial belongs in a `cmd`/`agent`/`tool` step. Member access on
  `null` returns `null` so a reference to a skipped step degrades
  gracefully; missing keys against a real value still error.
- The Starlark surface is an authoring DSL, not a runtime. A `.star`
  file evaluates at compile time and must call `workflow(name = ...,
  inputs = ..., steps = ..., output = ...)` exactly once. Standard
  Starlark features (`def`, `for`, `if`, list/dict comprehensions,
  `load(...)`) are available for *building* the document; references
  between steps are written as `${...}` strings. There is no runtime
  suspension and no introspection of step outputs at compile time.
- The workflows NIF lives in `native/condukt_workflows/`. Surface:
  `compile/2` (Starlark to JSON) and `parse_only/2` (early syntax
  check). Schema validation and execution are pure Elixir.
- `Condukt.Workflows.Executor` is the dispatch point for step kinds on
  the Elixir side. Add new kinds there and in the schema together.
- CLI verbs are `condukt run PATH [--input JSON]`,
  `condukt check PATH`, and `condukt compile PATH` (Starlark to JSON
  on stdout), mirrored by `mix condukt.run`, `mix condukt.check`, and
  `mix condukt.compile`. `run` and `check` accept `.json`, `.yaml`,
  `.yml`, and `.star` paths; `.star` is compiled transparently.
- Tool ids on `tool` steps are resolved through
  `Condukt.Workflows.ToolRegistry`. Built-ins
  (`Read`/`Write`/`Edit`/`Glob`/`Grep`/`Bash`) are registered out of
  the box; callers extend the registry by passing
  `tools: %{id => spec}` as an option to `Condukt.Workflows.run/3`.
- Future slices will add: remote `load(...)` of versioned helpers from
  GitHub URLs (with compiled JSON cached locally), an opt-in `--lock`
  integrity file, triggers (`condukt.trigger.webhook`,
  `condukt.schedule.cron`) declared at the top of the JSON document,
  and a visual editor that reads and writes the same JSON.

## Engine releases

- Condukt has two distribution modes. Library mode is the Hex package consumed
  by Elixir applications. Engine mode is the standalone `condukt` executable
  built with Burrito for running workflow projects without a local Elixir or
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
- Engine builds set `CONDUKT_BASHKIT_PRECOMPILED=1` and
  `CONDUKT_WORKFLOWS_PRECOMPILED=1` so the release bytecode points at the
  target-specific NIF artifacts already attached to the GitHub release.

## Workflow

- After every change, create a git commit and push it to the current branch.

## Elixir

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

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
  `Condukt.Sandbox.Microsandbox` is in-tree and routes through a Rust
  NIF wrapping the `microsandbox` crate for microVM-backed execution
  against bind-mounted host workspaces. Runtime `mount/3` is not
  supported there; use init-time `:mounts`. `Condukt.Sandbox.Kubernetes`
  runs each session in a dedicated pod via the `:k8s` library;
  idempotent on a stable `:id` so an Oban-style worker can reattach the
  same pod across job retries. K8s sandboxes refresh a heartbeat
  annotation for stale-pod reaping, support `reap_stale/1`, stream
  writes through exec stdin, and can clone an init-time
  `:workspace_source` git repository when the image includes `git`.
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
  `...K8s.ControlBridge`). `ControlBridge` is one per session,
  supervised as a `:transient` child of a `DynamicSupervisor`
  (registered name from `Condukt.Application.control_channel_supervisor/0`)
  under the app root: the standard dynamic-children pattern, not
  start_linked from the session. It monitors the session owner and
  stops `:normal` when the owner goes away (dropped, not restarted: no
  orphaned socket; not linked to the session so no cascade either
  way); a crash is restarted; an unreachable control port retries with
  backoff then gives up `:normal` (no crash-loop). Requires WebSocket
  port-forward (Kubernetes >= 1.30, KEP-4006) and the
  `pods/portforward` RBAC verb; `allow`/`deny`-only policies do not.
  There is no `condukt-egress` control-bridge subcommand.
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
  client, exposing each server's tools to agents under `<server>.<tool>`
  ids. See `guides/mcp.md` for transports and auth shapes.
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
- Child sessions inherit the parent `:sandbox`, `:cwd`, `:model`,
  `:thinking_level`, `:api_key`, `:base_url`, and resolved `:secrets` unless
  those values are overridden in the role registration opts.
- See `guides/subagents.md` for declaration, inheritance, and supervision
  details.

## Agent runtimes

- Agents can be declared with `use Condukt.Agent, runtime: RuntimeModule` or
  `runtime: {RuntimeModule, opts}`. The default runtime is
  `Condukt.AgentRuntimes.Native`, where `Condukt.Session` drives the ReqLLM
  turn and tool loop.
- Non-native runtime modules implement `Condukt.AgentRuntime.run/3`. Condukt
  still owns session identity, sandbox setup, secret resolution, project
  instructions, telemetry, and sub-agent boundaries.
- Built-in SDK runtime adapters are `Condukt.AgentRuntimes.Codex`, which shells
  out to `codex exec`, and `Condukt.AgentRuntimes.Claude`, which shells out to
  `claude --print`. Both use `MuonTrap`, the session cwd, and resolved session
  secrets.
- Treat `model/0`, `thinking_level/0`, `tools/0`, `mcp_servers/0`, and
  native tool-loop callbacks as native-only unless a runtime adapter documents
  an explicit mapping. Use `system_prompt/0` for durable guidance to
  runtime-backed agents; Condukt passes the composed prompt to the runtime.
- See `guides/agents.md` for runtime boundary and callback implications.

## Native NIFs

- `native/condukt_bashkit/` wraps the bashkit virtual sandbox into a
  NIF. Build it with `cd native/condukt_bashkit && cargo build --release`
  or via `MIX_ENV=dev mix compile`.
- `native/condukt_microsandbox/` wraps the `microsandbox` crate into a
  NIF for `Condukt.Sandbox.Microsandbox`. Build it with
  `cd native/condukt_microsandbox && cargo build --release` or via
  `MIX_ENV=dev mix compile`.
- Toolchain: Rust 1.94.x, pinned in each crate's `rust-toolchain.toml`
  and in `mise.toml`.
- `mix compile` source-builds both NIFs in `MIX_ENV=dev`. Other Mix
  environments download the precompiled artifacts from the GitHub release
  when the target is supported.
- The release publish job runs with `MIX_ENV=prod` so Hex package
  validation and publishing exercise the precompiled NIF path.
- Releases must publish precompiled artifacts for every target listed in
  `lib/condukt/bashkit/nif.ex` and `lib/condukt/microsandbox/nif.ex`,
  plus checksum files named `checksum-Elixir.Condukt.Bashkit.NIF.exs`
  and `checksum-Elixir.Condukt.Microsandbox.NIF.exs` in the package
  source. See `.github/workflows/release.yml` for the build matrix.

## Git

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
- Deployment: automatic Cloudflare Pages deployment is currently disabled in `.github/workflows/website.yml` because the Cloudflare API limit has been reached. The workflow still builds the site for validation. When re-enabled, pushes to `main` that touch `website/**` deploy to the Cloudflare Pages project `condukt-website` with `cloudflare/wrangler-action` (`wrangler pages deploy`) and read `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from repo secrets. The custom domain `condukt.tuist.dev` is bound to that Pages project in the Cloudflare dashboard.
- Pages config: `website/wrangler.toml` declares the project name and `pages_build_output_dir`.
- Toolchain: Node and aube are pinned in `mise.toml`; bump there rather than ad-hoc.

## Documentation (`guides/`)

Per-feature ExDoc pages live under `guides/` and are wired into `mix.exs` via `extras` and `groups_for_extras`. They are published to HexDocs alongside the API reference.

- When adding, removing, or meaningfully changing a feature (tools, sessions, compaction, redaction, providers, telemetry, project instructions, streaming, etc.), update the corresponding page under `guides/` in the same change.
- When introducing a new top-level feature, add a new guide page and register it in both `extras` and `groups_for_extras` in `mix.exs`.
- Avoid em dashes in guide prose (use colons, commas, or periods).
- Verify with `mix docs` before committing.

## Keeping this file up to date

- Whenever a change adds, removes, or meaningfully alters an agent capability, deployment target, or required tool, update this file in the same change. The agent reads `AGENTS.md` at startup and stale entries cause it to act on outdated assumptions.

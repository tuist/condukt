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
- See `web/priv/docs/framework/elixir/sandbox.md` for behaviour shape and how to add custom sandboxes.

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
- See `web/priv/docs/framework/elixir/network-policy.md` for topology, the policy/decider
  model, context shape, telemetry, trust-injection details, and
  limitations. Keep deep architecture there, not here.

## MCP

- Condukt connects to external Model Context Protocol servers as a
  client, exposing each server's tools to agents under `<server>.<tool>`
  ids. See `web/priv/docs/framework/elixir/mcp.md` for transports and auth shapes.
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

## Sessions

- `Condukt.Sessions` starts sessions under the library's own supervisor and
  registers them by id, so `Condukt.Sessions.via(id)` is accepted anywhere a
  session is. Prefer it to calling an agent's `start_link/1` directly: without a
  registry there is no way to reattach a reconnecting caller, count what is
  running, or shut a set down in order.
- Sessions are `:temporary`. A conversation that crashed must not be silently
  restarted underneath the person having it, because it would come back without
  the turn it died in. Restarting is the caller's decision.
- `Condukt.Session` state that belongs to the running turn lives in
  `Condukt.Session.Turn`, and translation to and from ReqLLM lives in
  `Condukt.Session.Translate`. Keep adding to those rather than to the session
  module, which was a single 1,371-line file holding eight unrelated jobs and is
  the reason both exist. The session struct is also near the 32-key limit that
  decides whether the virtual machine stores it as a flat map: group related
  fields rather than adding another.
- Session events reach the caller that subscribed. `Condukt.Notifier` is the
  seam for delivering them anywhere else, and `Condukt.Notifiers.PubSub` is the
  implementation for many viewers or more than one node. Subscribers are
  monitored, so a viewer that crashes is dropped rather than accumulating.
- Native model requests compact history before translation on every buffered or streaming tool-loop iteration, not only after run completion. `Condukt.Session.Compaction` owns dispatch and payload-free start/stop telemetry, including byte sizes and whether pruning changed anything. Keep model context and per-turn checkpoint telemetry on the same compacted messages; custom compactors must tolerate repeated no-op application.
- Native ReqLLM calls accept `:llm_request_options`; optional World Wide Web
  Consortium Trace Context is captured at each public run or stream boundary,
  then forwarded through tasks, tools, and sub-agents without requiring an
  OpenTelemetry exporter. The generated request headers are provider-neutral:
  `traceparent`, optional `tracestate`, and `baggage`; the opaque
  `condukt.session.id` baggage value provides session grouping metadata.

## Running the loop without a virtual machine

- `Condukt.HostSession` is the agent loop with the host doing the work: it holds
  conversation state and says what should happen next, while the caller performs
  inference and runs tools. No processes, no input or output, no dependencies
  beyond `Condukt.Message`. Use it when the caller owns the provider call, and
  `Condukt.Session` when Condukt should.
- It began as a port of the Rust `condukt_session::HostSession` behind the
  `@tuist/condukt` browser package. Those crates and that package are gone, so
  this is the only host-driven loop and is free to change on its own terms.
- There is no browser build any more, and reaching for one is a decision, not a
  gap to fill. Elixir in a browser means AtomVM through Popcorn, which pins OTP
  26.0.2 and Elixir 1.17.3 exactly and produces a bundle an order of magnitude
  larger than the 109 KB WebAssembly module the deleted Rust crates built. The
  measurements are in the commit that added this module. The web terminal
  solves the same problem differently: the loop runs on the server and calls
  the page's tools over the LiveView socket.

## Persistence

- `Condukt.SessionStore` is a snapshot cache, not a repository: no listing, no
  querying, no tenancy, and `save/2` replaces the whole snapshot. Its moduledoc
  says so, and it should stay that way. Anything needing to ask questions across
  sessions owns its own persistence.
- `Condukt.SessionStore.Snapshot` carries `:version`, and every load goes
  through `Snapshot.migrate/1`. When the shape changes, raise the version and
  add a clause; never change a field's meaning in place, because snapshots
  written by older builds exist on real disks.
- Version 3 retains assistant `{:reasoning_details, list}` blocks losslessly through
  ReqLLM translation and snapshots. These are provider replay state, not display
  text or thinking summaries. Keep them intact across tool turns and compaction.

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
- See `web/priv/docs/framework/elixir/subagents.md` for declaration, inheritance, and supervision
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
- See `web/priv/docs/framework/elixir/agents.md` for runtime boundary and callback implications.

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
- The GitHub release is created, and its artifacts checked as downloadable,
  **before** the package is published to Hex. The order is load-bearing: the
  library resolves its native artifacts from the release's download URL, so a
  version on Hex whose release does not exist cannot be compiled by anyone, and
  the only advice the resulting error can offer is to install Rust and build
  from source. Versions 1.8.0 through 1.10.0 shipped that way. Never move the
  Hex publish ahead of the release again.
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

## Licensing

- The repository is MIT, and `LICENSE` at the root is what covers the library,
  and the Rust NIFs under `native/`. `MIT.md` is a
  copy of the same text shipped inside the Hex package.
- `web/` is Mozilla Public License 2.0 and carries its own `web/LICENSE`, which
  is the canonical text unmodified. A file is covered by the licence in its
  nearest enclosing directory, so the server's terms stop at that directory and
  never reach anything a consumer depends on.
- One exception, and it matters: `web/priv/docs/` carries its own MIT `LICENSE`.
  The Hex package ships `web/priv/docs/framework/elixir` as the ExDoc extras, so
  without it an MIT package would contain files from an MPL-2.0 tree. If the
  package's `files` list ever grows another path under `web/`, check which
  licence covers it before adding it.
- When adding a manifest, declare the licence that matches its directory rather
  than defaulting to MIT, and never point `license-file` at a path outside the
  crate's own tree.

## Marketing site (`web/`)

The marketing site and public docs live under `web/` as a Phoenix application named `condukt_site` (modules under `ConduktSite.*`). It serves the install story, hosts the documentation pages, and runs the terminal on the home page.

- Source: `web/lib/`, `web/priv/`, `web/assets/`, `web/config/`, `web/test/`. Docs source files live under `web/priv/docs/{cli,framework}/`. Blog posts live under `web/priv/blog/posts/`.
- Package manager: [Hex](https://hex.pm/) for Elixir dependencies; `npm` is not used in the web app.
- Build: `cd web && mix deps.get && mix assets.deploy && mix release`.
- Local preview: `cd web && mix setup && mix phx.server`. The server prints a worktree-specific address; each Git worktree receives a stable suffix from 100 through 999 and uses port `4000 + suffix` plus a database named `condukt_site_dev_SUFFIX`. Tests use `4002 + suffix` and `condukt_site_test_SUFFIX`. Set `CONDUKT_SITE_DEV_INSTANCE` to an unused suffix when an explicit value is useful.
- Deployment: pushes to `main` that touch `web/**`, `lib/**`, `mix.exs`, `mix.lock`, or `infra/**` publish a Docker image to `ghcr.io/tuist/condukt` and then run `helm upgrade --install` against the production cluster, all in `.github/workflows/condukt-web.yml`. `lib/**` is in that list because the site depends on the library. The Dockerfile at `web/Dockerfile` takes the repository root as its build context for the same reason.
- The site answers `GET /ready` with `ok`. The Kubernetes probes depend on it, so keep the route out of the browser pipeline and free of external dependencies.
- The terminal on the home page is `ConduktSiteWeb.TerminalLive`: a real `Condukt.Session` per visitor, started on the page's first message with tools the page declares. `ConduktSite.BrowserTools` turns each declaration into a tool whose call travels back down the LiveView socket for the browser to run, so the loop is the server's and the reach is the page's. Keeping the GitHub reads in the browser also keeps that rate limit per visitor rather than per server.
- The composer below the transcript is deliberately not a LiveView form. Those controls are Noora custom elements holding their own state and the transcript above them re-renders on every streamed fragment, so the `ConduktTerminal` hook owns submission and busy state instead. Do not "fix" this by binding `phx-change`/`phx-submit` to them.
- The web app depends on `{:condukt, path: ".."}`. `web/mix.exs` sets `CONDUKT_BASHKIT_DISABLE` and `CONDUKT_MICROSANDBOX_DISABLE` itself so a path dependency does not force-build both Rust crates; the site never starts those sandboxes. The hosted Condukt service is not in scope.
- `web/assets/js/*.test.mjs` runs under `node --test` in `.github/workflows/condukt-web.yml`. The browser half of the tool contract lives there, so it is not optional.

## Cluster deployment (`infra/`)

The site runs on Kubernetes and is served at https://condukt.dev.

- `infra/helm/condukt-site/`: the Helm chart (Deployment, Service, Ingress with cert-manager TLS, ExternalSecrets, optional HPA, PDB, and CloudNativePG cluster). `infra/helm/condukt-site/tests/render-conditionals.sh` asserts the conditional paths render; CI lints and runs it on every pull request.
- `infra/k8s/ci-service-account.yaml`: the `condukt-production` namespace and the RBAC for the GitHub Actions deployer, applied by hand once. `infra/k8s/onboarding.md` is the runbook.
- The site is a tenant of the shared `tuist-k8s-production` cluster, not a cluster of its own, in the same way `once-production` is.
- DNS is hand-managed. `condukt.dev` is its own Cloudflare zone, and `platform-external-dns` filters on `tuist.dev`, so it never sees this host and creating the Ingress does not create the record. The apex A record points at the shared ingress LoadBalancer (`91.98.14.217`), DNS only, matching `buildonce.dev`. Do not widen that controller's domain filter or add a second one for `tuist.dev`; it runs `policy=sync` and owns that zone.
- TLS comes from a namespaced `Issuer` (`letsencrypt-condukt`) that the chart ships, solving DNS-01 with a Cloudflare token scoped to `condukt.dev` and synced by ESO from `cloudflare-condukt-dns`. The shared `letsencrypt-cloudflare` ClusterIssuer only holds a `tuist.dev` token and cannot issue for this host; clearing `ingress.issuer` falls back to it for a cluster where it does apply.
- `SECRET_KEY_BASE` is the only required secret. The `onepassword` ClusterSecretStore is pinned to the `tuist-k8s-production` vault, so chart secrets resolve there; the deploy kubeconfig lives in `condukt-k8s-production` and is read by the 1Password CLI in CI. OpenRouter sign-in is PKCE, so no provider credential lives in the cluster.
- The site has no database. `postgres.enabled` is `false` and the app starts its Repo only when `DATABASE_URL` is set; enabling the value provisions the cluster and wires the URL in.
- Verify chart changes with `helm lint infra/helm/condukt-site` and `./infra/helm/condukt-site/tests/render-conditionals.sh` before committing.
- `helm`, `kubectl`, and `jq` are declared in `mise.toml` and pinned by `mise.lock`, like every other tool. Do not pass inline versions (`helm@x.y.z`) in a workflow: change `mise.toml` and run `mise lock --platform linux-x64,macos-arm64`. Workflow steps call `$(mise which helm)` rather than a bare `helm`, because the GitHub runner image ships its own Helm ahead of the mise shim in `PATH`.

## Documentation (`web/priv/docs/`)

All prose documentation has a single source under `web/priv/docs/`, served by the Phoenix site and, for the Elixir pages, published to HexDocs by ExDoc. There is no `guides/` directory.

- `web/priv/docs/framework/`: the framework journey ("Build agents"), with `elixir/` for the Hex library.
- The Elixir pages under `web/priv/docs/framework/elixir/` are also the ExDoc extras. They are listed in `mix.exs` under `extras` and `groups_for_extras`, and the root mix `package` includes that directory.
- Cross-link rules: pages that are ExDoc extras link to their siblings with relative Markdown paths (`tools.md`, `sandbox.md#custom`) so both surfaces resolve them. Site-only pages link with root-relative paths (`/framework/rust/browser`), which the site rewrites to `/docs/...`.
- When adding, removing, or meaningfully changing a feature (tools, sessions, compaction, redaction, providers, telemetry, project instructions, streaming, etc.), update the corresponding page in the same change.
- When adding a page, register it in `web/lib/condukt_site_web/docs/navigation.ex`, and, for an Elixir page, in both `extras` and `groups_for_extras` in `mix.exs`. `mix test` in `web/` fails on navigation entries and internal links that point at missing pages.
- Avoid em dashes in documentation prose (use colons, commas, or periods).
- Verify with `mix docs` at the repository root and `mix test` in `web/` before committing.

## Keeping this file up to date

- Whenever a change adds, removes, or meaningfully alters an agent capability, deployment target, or required tool, update this file in the same change. The agent reads `AGENTS.md` at startup and stale entries cause it to act on outdated assumptions.

---
name: condukt-elixir-review
description: Project-specific PR-review rules for the Condukt Elixir codebase. Focuses on command execution, cwd scoping, session restore precedence, session store safety, Mimic placement, and the repo's no-typespec convention.
---

# Condukt Elixir Review

This skill is intentionally narrow. Generic Elixir style, naming,
formatting, and pipe-chain hygiene are already covered by `mix format`
and `credo` in CI, so do not flag those. Focus on the rules below.

For each finding, cite `path:line` and quote the relevant snippet.

---

## 1. Command execution must use MuonTrap

The repo convention is to use `MuonTrap` for command execution so child
processes are cleaned up with the calling process.

### Flag

- **New command execution in library code or built-in tools that uses
  `System.cmd/3`, `Port.open/2`, `:os.cmd/1`, or another direct OS
  process primitive instead of `MuonTrap`.** This breaks the repo's
  shutdown guarantees. **Severity: high.**

### Do not flag

- `System.get_env/1`, `System.fetch_env!/1`, `System.monotonic_time/0`,
  and `System.system_time/0`.
- Documentation examples that show reading environment variables.

## 2. Tool and session-store filesystem work must honor the configured cwd

Built-in tools and session stores are designed to operate relative to
`context[:cwd]` or `opts[:cwd]`, not the VM's process cwd. This matters
for multiple agents running concurrently against different directories.

### Flag

- **New or modified code under `lib/condukt/tools/` that reads or writes
  files without first resolving relative paths against `context[:cwd]`
  (or an explicit cwd argument).** **Severity: high.**
- **New or modified session-store code that writes its default files
  outside `opts[:cwd]` or uses a raw relative path.** **Severity:
  medium.**
- **Changes that replace `context[:cwd] || File.cwd!()` or `opts[:cwd]`
  with unconditional `File.cwd!()` for file access.** **Severity:
  medium.**

### Do not flag

- Calls to `File.cwd!/0` that are only used as a fallback when no
  explicit cwd is available.

## 3. Session restore precedence must stay explicit opts > config > snapshot

`Condukt.Session.start_link/2` tracks explicit keys and uses
`restore_value/3` so persisted session settings never overwrite values
passed directly to `start_link/1`.

### Flag

- **Changes to `lib/condukt/session.ex` that allow persisted snapshots or
  application config to override explicit `start_link/1` options** for
  `:model`, `:thinking_level`, `:system_prompt`, `:cwd`, or `:api_key`.
  **Severity: high.**
- **Changes that stop restoring persisted messages when a session store
  is configured.** **Severity: medium.**
- **New session-store-related code that drops caller-provided keys such
  as `:agent_module`, `:cwd`, or custom store options during option
  merging.** **Severity: medium.**

### Do not flag

- Tests that assert the current precedence rules.

## 4. Session-store contract and disk safety

`Condukt.SessionStore.load/1` returns `:not_found` when no snapshot
exists. `Condukt.SessionStore.Disk` decodes snapshots with
`:erlang.binary_to_term(binary, [:safe])`.

### Flag

- **A session-store implementation that returns `nil`,
  `{:error, :enoent}`, or another shape instead of `:not_found` for
  missing state.** **Severity: medium.**
- **Disk snapshot decoding that drops `[:safe]` or otherwise deserializes
  untrusted Erlang terms unsafely.** **Severity: high.**
- **Changes to the disk-store default path that stop using
  `.condukt/session.store` under the configured cwd when no explicit
  `path:` was provided.** **Severity: medium.**

## 5. Elixir production code should not add typespecs or custom types

This repo does not want `@spec`, `@type`, `@typep`, or `@opaque` in
production Elixir code. Callback definitions are the exception when a
behaviour contract needs to exist, but reviewers should not ask for or
encourage additional typespec-style annotations beyond that.

### Flag

- **Any *net-new* `@spec`, `@type`, `@typep`, or `@opaque` being added to
  `lib/` for the first time.** Do not flag existing typespecs that appear
  in a diff due to code movement, refactoring, or line shifts. Only flag
  genuinely new type annotations. **Severity: medium.**
- **Typed signatures in `@callback` declarations** (e.g.,
  `@callback foo() :: return_type()`). Plain `@callback foo()` without
  the type signature is preferred; document return shapes in `@doc` as
  prose. **Severity: medium.**
- **Review feedback that asks for missing typespecs, type aliases, or
  stronger type annotations in Elixir production code.**
  **Severity: medium.**

### Do not flag

- Plain `@callback` / `@macrocallback` declarations without typed
  signatures, when a behaviour contract is necessary.
- `@callback` declarations that already exist and are only appearing in
  diffs due to code movement.
- Plain runtime validation, guards, or pattern matching that make code
  safer without adding typespec annotations.
- Existing typespecs that are being modified but were already present in
  the codebase before the PR.

## 6. Elixir production code should avoid `rescue`

Prefer functions and APIs that return tagged tuples, then handle them
with `case`, `with`, and pattern matching. Do not add `rescue` blocks
in `lib/` just to normalize control flow. If a boundary truly must
observe non-local failures, keep it narrow and explicit.

### Flag

- **New `rescue` blocks in `lib/` that are not at a clear system
  boundary.** Use tagged tuples and pattern matching instead.
  **Severity: medium.**
- **Code review feedback that asks for `rescue` around ordinary control
  flow that could be handled with tagged tuples and matching.**
  **Severity: medium.**

### Do not flag

- Explicit pattern matching with `case`, `with`, function heads, or
  guards.
- Narrow boundary code in `lib/condukt/sandbox/virtual.ex` or
  `lib/condukt/sandbox/local.ex` that handles NIF initialization
  failures, MuonTrap execution monitoring, or external library
  instrumentation where return values alone cannot capture all failure
  modes. Keep such exception handling as narrow as possible.
- `try/catch` or `try/rescue` in test files (outside `lib/`).

## 7. Mimic copies belong in `test/test_helper.exs`

This repo centralizes `Mimic.copy(...)` in `test/test_helper.exs`.

### Flag

- **Any `Mimic.copy(...)` call outside `test/test_helper.exs`.** Per-file
  copies are a repo-specific test smell here. **Severity: medium.**

### Do not flag

- `use Mimic`
- `expect/3`, `stub/3`, `reject/1`
- `set_mimic_from_context`
- `verify_on_exit!/0`

## Out of scope (handled elsewhere - do not flag)

- Generic naming, formatting, module layout, or pipe style
- Missing docs
- README wording tweaks unless they violate one of the rules above

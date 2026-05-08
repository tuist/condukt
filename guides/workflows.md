# Workflows

A workflow is a typed JSON document describing a directed acyclic graph
of steps. The document is the source of truth: it is what `condukt
run` executes, what `condukt check` validates, and what editors and
agents read and write. The basename of the file is the run name.

There is no project layout, manifest, or lockfile. To run a workflow
you point the engine at a `.json`, `.yaml`, or `.exs` path.

## A first workflow

Author workflows as `.exs` files when you want the most ergonomic
format. The script's final expression evaluates to the workflow
document.

`hello.exs`:

```elixir
%{
  name: "hello",
  inputs: %{
    name: %{type: :string}
  },
  steps: %{
    greet: %{
      kind: :cmd,
      argv: ["echo", "Hello, ${inputs.name}"]
    }
  },
  output: "${steps.greet.stdout}"
}
```

Run it with the standalone engine or with Mix:

```sh
condukt run hello.exs --input '{"name":"world"}'
mix condukt.run hello.exs --input '{"name":"world"}'
```

The resolved `output` expression is printed on stdout. Strings are
printed as is, other values are JSON-encoded.

## The schema

The workflow document is validated against a published JSON Schema.
The canonical source lives in this repository at
`priv/schemas/condukt.workflow.schema.json` and is reachable on GitHub
at:

```
https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json
```

Reference it from a workflow file with the standard `$schema` key so
editors pick up auto-completion and validation.

The top-level shape is:

```jsonc
{
  "name": "review-pr",            // optional, defaults to file basename
  "inputs": { ... },              // typed input map (JSON Schema fragments)
  "steps": { "<id>": { ... } },   // map of step id to step definition
  "output": "<expression>"        // optional, what `condukt run` prints
}
```

A step has the shape:

```jsonc
{
  "kind": "cmd" | "agent" | "http" | "tool" | "map",
  "needs": ["other_step"],        // explicit dependencies, optional
  "when": "<expression>",         // optional gate; step is skipped if false
  // ...kind-specific fields
}
```

Implicit dependencies are inferred from `${steps.X.*}` references
inside any field, so `needs:` is only required when the dependency is
purely ordering and not data flow.

## Step kinds

- `cmd`: runs an executable on the host. Fields: `argv` (list of
  strings, required), `cwd` (optional), `env` (optional dict).
  Outputs: `stdout`, `exit_code`, `ok`.
- `agent`: runs an LLM-driven step. Fields: `model` (required),
  `input` (required, any), `tools` (optional list of tool ids),
  `system` (optional system prompt), `output_schema` (optional JSON
  Schema for structured output). Output: `output` and `ok`.
- `http`: deterministic HTTP call. Fields: `method`, `url`, `headers`,
  `body`, `expect_status`. Output: `status`, `headers`, `body`.
- `tool`: invokes a registered host tool by id. Fields: `id`, `args`.
  Output: `output` and `ok`.
- `map`: fan-out. Fields: `over` (expression resolving to a list),
  `as` (binding name), `do` (a sub-step definition). Output: a list of
  the sub-step's outputs in input order.

Each step's outputs are addressable as `${steps.<id>.<field>}` from
later steps and from the top-level `output`.

## Expressions

Expressions live between `${` and `}`. They are evaluated against
`inputs`, `steps`, and (inside a `map` step) the `as` binding.

Supported:

- Member access: `inputs.name`, `steps.fetch.body.title`
- Indexing: `steps.list.items[0]`, `obj["a key"]`, negative indices
- Comparisons: `==`, `!=`, `<`, `<=`, `>`, `>=`
- Boolean: `&&`, `||`, `!`
- Unary minus: `-1`, `xs[-1]`
- Literals: strings, numbers, booleans, null, parens
- Type-aware formatters: `${var:json}`, `${var:csv}`

Not supported:

- Arbitrary function calls, regex, or arithmetic beyond comparisons.
  Anything more substantial belongs in a `cmd`, `agent`, or `tool`
  step.

A `when:` expression must evaluate to a boolean. Member access on
`null` returns `null` so a reference to a skipped step degrades
gracefully; typos against a real value still raise a loud error.

## Skipping and cascade

If a step's `when:` evaluates to false, the step is skipped. Any
downstream step whose declared or inferred dependencies include a
skipped step is also skipped. The step's slot in `steps.<id>` is set
to `null`.

## JSON and YAML

JSON files (`.json`) are accepted as the canonical workflow document
format. The first `.exs` workflow compiles to this document:

```json
{
  "$schema": "https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json",
  "inputs": {
    "name": { "type": "string" }
  },
  "steps": {
    "greet": {
      "kind": "cmd",
      "argv": ["echo", "Hello, ${inputs.name}"]
    }
  },
  "output": "${steps.greet.stdout}"
}
```

YAML files (`.yaml`, `.yml`) are accepted and converted to the same
JSON document at load time:

```yaml
$schema: https://raw.githubusercontent.com/tuist/condukt/main/priv/schemas/condukt.workflow.schema.json
inputs:
  name:
    type: string
steps:
  greet:
    kind: cmd
    argv: ["echo", "Hello, ${inputs.name}"]
output: "${steps.greet.stdout}"
```

## Authoring DSL (`.exs`)

Use `.exs` for authored workflows. JSON and YAML remain useful as
generated or interchange formats, while an Elixir script gives you a
small DSL whose final expression evaluates to a map describing the
workflow. The file evaluates at load time and lets you use `def`
(inside a `defmodule`), anonymous functions, `for`, `if`,
comprehensions, and the rest of the standard library to build the
document programmatically. References between steps are written as
plain `${...}` expression strings: there is no runtime introspection
of step outputs at compile time.

Atom keys and atom values (other than `nil`/`true`/`false`) are
normalized to strings before validation, so the file can use the
familiar Elixir map syntax.

Compile a workflow when you need the canonical JSON output:

```sh
condukt compile hello.exs > hello.json
```

`condukt run hello.exs` does that compile step transparently before
validation and execution.

A more substantial example uses a comprehension to fan out commands
over a static list of stages:

```elixir
stages = ["lint", "test", "build"]

steps =
  for stage <- stages, into: %{} do
    {stage, %{kind: :cmd, argv: ["./script/" <> stage]}}
  end

%{
  steps: steps,
  output: for(stage <- stages, into: %{}, do: {stage, "${steps.#{stage}.stdout}"})
}
```

The result of the file's last expression is the workflow document.
Any Elixir feature is fair game for *building* the data; it is
`${...}` expression strings, not Elixir values, that represent
runtime references between steps.

## Validating a workflow

`condukt check PATH` parses and validates the document against the
schema and reports all problems without executing it. It accepts
`.json`, `.yaml`, `.yml`, and `.exs` paths.

```sh
condukt check review-pr.json
condukt check review-pr.exs
```

Use it in CI or as part of an LLM authoring loop: generate, check,
fix, repeat.

## Future direction

These are planned but not yet implemented:

- A Hex-package convention for sharing reusable workflow helpers
  (e.g., `MyOrg.Workflows.lint_step/1`) so an `.exs` file can `use`
  or `import` them.
- Optional `--lock` mode that records SHA-256 per fetched URL and
  verifies on later runs (Deno-style integrity).
- Triggers (`condukt.trigger.webhook`, `condukt.schedule.cron`) and
  `condukt serve PATH` to host webhook and cron-driven runs.
- Visual editor that reads and writes the same JSON document.
